import "dotenv/config";
import { ethers } from "ethers";
import { getNetworkAddresses } from "../config/networks.js";

/**
 * Configuration interface for enhanced payment system
 */
interface PaymentConfig {
  // Network configuration
  rpcUrl: string;
  privateKey: string;
  chainId: number;

  // Contract addresses
  gravityPaymentAddress: string;
  tokenRouterAddress: string;
  mneeTokenAddress: string;
  universalRouterAddress: string;
  permit2Address: string;

  // Gas and slippage settings
  maxGasPrice?: string;
  defaultSlippageBps?: number; // basis points
  maxSlippageBps?: number;
}

/**
 * Token information structure
 */
interface TokenInfo {
  address: string;
  symbol: string;
  decimals: number;
  name: string;
  logoURI?: string;
  isStable?: boolean;
  liquidityScore?: number;
}

/**
 * Swap route information
 */
interface SwapRoute {
  path: string[];
  expectedOutput: string;
  priceImpact: number;
  gasEstimate: string;
  intermediateTokens: string[];
  confidence: number; // 0-100 route quality score
}

/**
 * Payment result information
 */
interface PaymentResult {
  paymentId: string;
  originalToken: string;
  originalAmount: string;
  mneeAmount: string;
  swapPath: string;
  txHash: string;
  gasUsed: string;
  timestamp: number;
  recipient: string;
}

/**
 * Enhanced Payment System using Gravity Contracts
 * Integrates with GravityPayment and TokenRouter for intelligent routing
 */
export class GravityPaymentSystem {
  private provider: ethers.JsonRpcProvider;
  private wallet: ethers.Wallet;

  // Smart contract instances
  private gravityPayment: ethers.Contract;
  private tokenRouter: ethers.Contract;
  private universalRouter: ethers.Contract;
  private permit2: ethers.Contract;

  // ABIs for contracts
  private readonly GRAVITY_PAYMENT_ABI = [
    "function pay(uint256 eventId, address tokenIn, uint256 amountIn, address recipient, uint256 minMNEEOut, address[] calldata swapPath) external returns (uint256 paymentId, uint256 mneeAmount)",
    "function getQuote(address tokenIn, uint256 amountIn, address[] calldata swapPath) external view returns (uint256 expectedMNEE)",
    "function isTokenSupported(address token) external view returns (bool)",
    "function payments(uint256 paymentId) external view returns (tuple(uint256 eventId, address payer, address originalToken, uint256 originalAmount, uint256 mneeAmount, address recipient, uint256 timestamp, string swapPath))",
    "event PaymentMade(uint256 indexed paymentId, uint256 indexed eventId, address indexed payer, address recipient, address originalToken, uint256 originalAmount, uint256 mneeAmount, string swapPath, uint256 timestamp)"
  ];

  private readonly TOKEN_ROUTER_ABI = [
    "function calculateExpectedOutput(address tokenIn, uint256 amountIn, address[] memory path) external view returns (uint256 expectedOutput)",
    "function validatePath(address[] memory path) external view returns (bool)",
    "function getNeighbors(address token) external view returns (address[] memory)",
    "function getSupportedTokens() external view returns (address[] memory)",
    "function getIntermediateTokens() external view returns (address[] memory)",
    "function tokenRegistry(address token) external view returns (tuple(bool isSupported, bool isIntermediate, uint8 decimals, string symbol, uint256 liquidityScore, uint256 lastUpdated))",
    "event TokenRegistered(address indexed token, string symbol, uint8 decimals)"
  ];

  private readonly UNIVERSAL_ROUTER_ABI = [
    "function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline, uint256 value) external payable",
    "function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable"
  ];

  private readonly PERMIT2_ABI = [
    "function transfer(address token, address from, address to, uint160 amount) external",
    "function allowance(address token, address owner, address spender) external view returns (uint160, uint48, uint48)"
  ];

  private readonly ERC20_ABI = [
    "function approve(address spender, uint256 amount) external returns (bool)",
    "function allowance(address owner, address spender) external view returns (uint256)",
    "function balanceOf(address account) external view returns (uint256)",
    "function transfer(address to, uint256 amount) external returns (bool)",
    "function decimals() external view returns (uint8)",
    "function symbol() external view returns (string)",
    "function name() external view returns (string)"
  ];

  constructor(private config: PaymentConfig) {
    this.provider = new ethers.JsonRpcProvider(config.rpcUrl);
    this.wallet = new ethers.Wallet(config.privateKey, this.provider);

    // Initialize contract instances
    this.gravityPayment = new ethers.Contract(
      config.gravityPaymentAddress,
      this.GRAVITY_PAYMENT_ABI,
      this.wallet
    );

    this.tokenRouter = new ethers.Contract(
      config.tokenRouterAddress,
      this.TOKEN_ROUTER_ABI,
      this.wallet
    );

    this.universalRouter = new ethers.Contract(
      config.universalRouterAddress,
      this.UNIVERSAL_ROUTER_ABI,
      this.wallet
    );

    this.permit2 = new ethers.Contract(
      config.permit2Address,
      this.PERMIT2_ABI,
      this.wallet
    );
  }

  /**
   * Discover optimal route for token conversion
   */
  async discoverRoute(
    tokenInAddress: string,
    amountIn: string,
    maxHops: number = 3
  ): Promise<SwapRoute> {
    try {
      const tokenInfo = await this._getTokenInfo(tokenInAddress);
      const hopLimit = Math.min(Math.max(maxHops, 1), 5);
      const path = await this._findRouteOffchain(
        tokenInAddress,
        this.config.mneeTokenAddress,
        hopLimit
      );

      const amountInWei = ethers.parseUnits(amountIn, tokenInfo.decimals);
      const expectedOutput = await this.tokenRouter.calculateExpectedOutput(
        tokenInAddress,
        amountInWei,
        path
      );

      const formattedOutput = ethers.formatUnits(expectedOutput, 18);
      const intermediateTokens = path.slice(1, -1);
      const confidence = this._calculateRouteConfidence(path, intermediateTokens.length);
      const priceImpact = this._estimatePriceImpact(amountIn, formattedOutput);
      const gasEstimate = this._estimateGasCost(path.length - 1);

      return {
        path,
        expectedOutput: formattedOutput,
        priceImpact,
        gasEstimate,
        intermediateTokens,
        confidence
      };

    } catch (error: any) {
      throw new Error(`Route discovery failed: ${error.message}`);
    }
  }

  /**
   * Execute payment with intelligent routing
   */
  async executePayment(
    eventId: string,
    tokenInAddress: string,
    amountIn: string,
    recipientAddress: string,
    options: {
      minMNEEOut?: string;
      maxHops?: number;
      slippageBps?: number;
    } = {}
  ): Promise<PaymentResult> {
    try {
      // Get token info
      const tokenIn = await this._getTokenInfo(tokenInAddress);
      const amountInWei = ethers.parseUnits(amountIn, tokenIn.decimals);

      // Discover route
      const route = await this.discoverRoute(
        tokenInAddress,
        amountIn,
        options.maxHops || 3
      );

      console.log(`🔍 Optimal route discovered:`);
      console.log(`   Path: ${route.path.map(addr => this._shortenAddress(addr)).join(' → ')}`);
      console.log(`   Expected MNEE: ${route.expectedOutput}`);
      console.log(`   Confidence: ${route.confidence}%`);
      console.log(`   Price Impact: ${route.priceImpact.toFixed(2)}%`);

      // Calculate minimum output with slippage
      const expectedMNEE = ethers.parseUnits(route.expectedOutput, 18);
      const slippageBps = options.slippageBps ?? this.config.defaultSlippageBps ?? 500; // 5% default
      const cappedSlippageBps = Math.max(
        0,
        Math.min(slippageBps, this.config.maxSlippageBps ?? 10_000)
      );
      const slippageBpsBigInt = BigInt(cappedSlippageBps);
      const minMNEEOut = options.minMNEEOut
        ? ethers.parseUnits(options.minMNEEOut, 18)
        : (expectedMNEE * (BigInt(10_000) - slippageBpsBigInt)) / BigInt(10_000);

      // Ensure token approval
      await this._ensureApproval(tokenInAddress, amountIn, tokenIn.decimals);

      console.log(`🔗 Executing payment across ${route.path.length - 1} hops...`);
      const txResponse = await this.gravityPayment.pay(
        eventId,
        tokenInAddress,
        amountInWei,
        recipientAddress,
        minMNEEOut,
        route.path
      );

      const receipt = await txResponse.wait();
      const paymentId = this._extractPaymentId(receipt);

      // Get payment details
      const paymentDetails = await this.gravityPayment.payments(paymentId);

      console.log(`✅ Payment completed successfully!`);
      console.log(`   Payment ID: ${paymentId}`);
      console.log(`   Original: ${amountIn} ${tokenIn.symbol}`);
      console.log(`   Received: ${ethers.formatUnits(paymentDetails.mneeAmount, 18)} MNEE`);
      console.log(`   Tx Hash: ${receipt.hash}`);
      console.log(`   Gas Used: ${receipt.gasUsed}`);

      return {
        paymentId,
        originalToken: tokenInAddress,
        originalAmount: amountInWei.toString(),
        mneeAmount: paymentDetails.mneeAmount.toString(),
        swapPath: paymentDetails.swapPath,
        txHash: receipt.hash,
        gasUsed: receipt.gasUsed?.toString() || "0",
        timestamp: Number(paymentDetails.timestamp),
        recipient: recipientAddress
      };

    } catch (error: any) {
      console.error(`❌ Payment execution failed:`, error);
      throw new Error(`Payment failed: ${error.message}`);
    }
  }

  /**
   * Get quote for payment without executing
   */
  async getPaymentQuote(
    tokenInAddress: string,
    amountIn: string,
    maxHops: number = 3
  ): Promise<{
    expectedMNEE: string;
    path: string[];
    confidence: number;
    priceImpact: number;
  }> {
    try {
      const tokenIn = await this._getTokenInfo(tokenInAddress);
      const amountInWei = ethers.parseUnits(amountIn, tokenIn.decimals);
      const route = await this.discoverRoute(tokenInAddress, amountIn, maxHops);

      const expectedWei = await this.gravityPayment.getQuote(
        tokenInAddress,
        amountInWei,
        route.path
      );

      return {
        expectedMNEE: ethers.formatUnits(expectedWei, 18),
        path: route.path,
        confidence: route.confidence,
        priceImpact: route.priceImpact
      };

    } catch (error: any) {
      throw new Error(`Quote generation failed: ${error.message}`);
    }
  }

  /**
   * Check if a token is supported for payments
   */
  async isTokenSupported(tokenAddress: string): Promise<boolean> {
    try {
      return await this.gravityPayment.isTokenSupported(tokenAddress);
    } catch (error) {
      return false;
    }
  }

  /**
   * Get token information from registry or on-chain
   */
  async getTokenInfo(tokenAddress: string): Promise<TokenInfo> {
    try {
      // Try to get from TokenRouter registry first
      const registryInfo = await this.tokenRouter.tokenRegistry(tokenAddress);

      if (registryInfo.isSupported) {
        return {
          address: tokenAddress,
          symbol: registryInfo.symbol,
          decimals: Number(registryInfo.decimals),
          name: registryInfo.symbol,
          liquidityScore: Number(registryInfo.liquidityScore)
        };
      }
    } catch (error) {
      // Fall back to direct ERC20 calls
    }

    // Fallback: query token directly
    return this._getTokenInfo(tokenAddress);
  }

  /**
   * Get supported intermediate tokens
   */
  async getIntermediateTokens(): Promise<string[]> {
    try {
      return await this.tokenRouter.getIntermediateTokens();
    } catch (error) {
      return [];
    }
  }

  // Private helper methods

  private async _getTokenInfo(tokenAddress: string): Promise<TokenInfo> {
    const tokenContract = new ethers.Contract(tokenAddress, this.ERC20_ABI, this.provider);

    const [name, symbol, decimals] = await Promise.all([
      tokenContract.name(),
      tokenContract.symbol(),
      tokenContract.decimals()
    ]);

    return {
      address: tokenAddress,
      name,
      symbol,
      decimals: Number(decimals)
    };
  }

  private async _ensureApproval(tokenAddress: string, amount: string, decimals: number): Promise<void> {
    const tokenContract = new ethers.Contract(tokenAddress, this.ERC20_ABI, this.wallet);

    const currentAllowance = await tokenContract.allowance(
      this.wallet.address,
      this.config.gravityPaymentAddress
    );

    const requiredAmount = ethers.parseUnits(amount, decimals);

    if (currentAllowance < requiredAmount) {
      console.log(`Approving GravityPayment to spend token: ${tokenAddress}`);
      const approveTx = await tokenContract.approve(
        this.config.gravityPaymentAddress,
        requiredAmount
      );
      await approveTx.wait();
      console.log("✅ Approval confirmed");
    }
  }

  private async _findRouteOffchain(
    tokenIn: string,
    tokenOut: string,
    maxHops: number
  ): Promise<string[]> {
    if (tokenIn.toLowerCase() === tokenOut.toLowerCase()) {
      return [tokenIn];
    }

    const normalizedOut = tokenOut.toLowerCase();
    const queue: string[][] = [[tokenIn]];
    const visited = new Set<string>([tokenIn.toLowerCase()]);
    const neighborCache = new Map<string, string[]>();

    while (queue.length > 0) {
      const currentPath = queue.shift()!;
      const last = currentPath[currentPath.length - 1];

      if (currentPath.length - 1 >= maxHops) {
        continue;
      }

      const neighborKey = last.toLowerCase();
      let neighbors = neighborCache.get(neighborKey);
      if (!neighbors) {
        const fetchedNeighbors = await this.tokenRouter.getNeighbors(last);
        neighborCache.set(neighborKey, fetchedNeighbors);
        neighbors = fetchedNeighbors;
      }

      if (!neighbors || neighbors.length === 0) {
        continue;
      }

      for (const neighbor of neighbors) {
        const neighborLower = neighbor.toLowerCase();
        if (visited.has(neighborLower)) {
          continue;
        }
        visited.add(neighborLower);

        const nextPath = [...currentPath, neighbor];
        if (neighborLower === normalizedOut) {
          const isValid = await this.tokenRouter.validatePath(nextPath);
          if (!isValid) {
            continue;
          }
          return nextPath;
        }

        queue.push(nextPath);
      }
    }

    throw new Error(`No path found within ${maxHops} hops`);
  }

  private _extractPaymentId(receipt: ethers.TransactionReceipt): string {
    const iface = new ethers.Interface(this.GRAVITY_PAYMENT_ABI);
    for (const log of receipt.logs) {
      try {
        const parsed = iface.parseLog(log);
        if (parsed?.name === "PaymentMade") {
          return parsed.args?.paymentId?.toString();
        }
      } catch (_) {
        // ignore logs that do not match the event signature
      }
    }
    throw new Error("PaymentMade event not found in receipt");
  }

  private _calculateRouteConfidence(path: string[], hopCount: number): number {
    // Simple confidence calculation based on hop count and token quality
    let confidence = 100;

    // Penalize longer routes
    confidence -= hopCount * 15;

    // Bonus for high-quality intermediate tokens (stablecoins, major tokens)
    const highQualityTokens = [
      "0xa0b86a33E6441E6c7B2D9a8C1C6c6e8D4E4d4e4D", // USDC
      "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", // WETH
      "0xdac17f958d2ee523a2206206994597c13d831ec7", // USDT
      "0x6b175474e89094c44da98b954eedeac495271d0f"  // DAI
    ].map(addr => addr.toLowerCase());

    for (const token of path.slice(1, -1)) { // Exclude input/output
      if (highQualityTokens.includes(token.toLowerCase())) {
        confidence += 10;
      }
    }

    return Math.max(Math.min(confidence, 100), 0);
  }

  private _estimatePriceImpact(amountIn: string, amountOut: string): number {
    // Simplified price impact calculation
    // In production, this would use actual pool liquidity data
    const ratio = parseFloat(amountOut) / parseFloat(amountIn);
    return Math.max(0, (1 - ratio) * 100);
  }

  private _estimateGasCost(hopCount: number): string {
    // Estimated gas: 150k base + 50k per hop
    const gasEstimate = 150000 + (hopCount * 50000);
    return gasEstimate.toString();
  }

  private _shortenAddress(address: string): string {
    return `${address.slice(0, 6)}...${address.slice(-4)}`;
  }
}

// Export default configuration for easy setup
export const DEFAULT_PAYMENT_CONFIG: Partial<PaymentConfig> = {
  chainId: 1, // Ethereum mainnet
  defaultSlippageBps: 500, // 5%
  maxSlippageBps: 2000, // 20%
  maxGasPrice: "50000000000", // 50 gwei
};

/**
 * Example usage function
 */
export async function examplePayment() {
  const config = buildPaymentConfigFromEnv();

  const paymentSystem = new GravityPaymentSystem(config);

  try {
    // Example: Pay with SHIB token
    const result = await paymentSystem.executePayment(
      "event-123", // Event ID
      "0x95ad61b0a150d79219dcf64e1e6cc01f0b64c4ce", // SHIB token
      "1000000", // 1M SHIB
      "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" // Recipient
    );

    console.log("Payment completed:", result);

  } catch (error) {
    console.error("Payment failed:", error);
  }
}

export function buildPaymentConfigFromEnv(): PaymentConfig {
  const fallbackChainId = DEFAULT_PAYMENT_CONFIG.chainId ?? 1;
  const chainId = Number(process.env.CHAIN_ID || fallbackChainId);
  const networkDefaults = getNetworkAddresses(chainId);

  const required = (envKey: string, fallback?: string) => {
    const value = process.env[envKey] || fallback;
    if (!value) {
      throw new Error(`Missing required environment variable: ${envKey}`);
    }
    return value;
  };

  return {
    rpcUrl: required("RPC_URL", "http://localhost:8545"),
    privateKey: required("PRIVATE_KEY"),
    chainId,
    gravityPaymentAddress: required("GRAVITY_PAYMENT_ADDRESS"),
    tokenRouterAddress: required("TOKEN_ROUTER_ADDRESS"),
    mneeTokenAddress: required("MNEE_TOKEN_ADDRESS"),
    universalRouterAddress: required(
      "UNIVERSAL_ROUTER_ADDRESS",
      networkDefaults?.universalRouter
    ),
    permit2Address: required(
      "PERMIT2_ADDRESS",
      networkDefaults?.permit2
    ),
    maxGasPrice: process.env.MAX_GAS_PRICE_WEI,
    defaultSlippageBps: process.env.DEFAULT_SLIPPAGE_BPS
      ? Number(process.env.DEFAULT_SLIPPAGE_BPS)
      : DEFAULT_PAYMENT_CONFIG.defaultSlippageBps,
    maxSlippageBps: process.env.MAX_SLIPPAGE_BPS
      ? Number(process.env.MAX_SLIPPAGE_BPS)
      : DEFAULT_PAYMENT_CONFIG.maxSlippageBps,
  };
}