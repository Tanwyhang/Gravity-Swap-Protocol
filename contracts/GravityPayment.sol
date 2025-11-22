// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {MNEESwapHook} from "./MNEESwapHook.sol";
import {TokenRouter} from "./TokenRouter.sol";

/**
 * @title GravityPayment
 * @notice Universal ERC20 payment processor with intelligent routing to MNEE
 * @dev Accepts any ERC20 token and performs optimal multihop swaps to MNEE
 *
 * Key Features:
 * - Universal ERC20 token acceptance
 * - Intelligent routing through popular intermediate tokens (USDC, WETH, USDT, DAI)
 * - Automatic path discovery and optimization
 * - Slippage protection and gas optimization
 * - Event emission for payment tracking and verification
 *
 * Architecture:
 * - Integrates with TokenRouter for path discovery
 * - Uses MNEESwapHook for Uniswap v4 swaps
 * - Maintains payment records for verification system
 *
 * Use Cases:
 * - Event ticketing with flexible payment options
 * - Service payments with automatic conversion to MNEE
 * - Cross-chain compatible payment processing
 * - Creator economy platforms
 */
contract GravityPayment is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // State variables
    IPoolManager public immutable poolManager;
    MNEESwapHook public immutable swapHook;
    TokenRouter public immutable tokenRouter;

    address public immutable MNEE_TOKEN;
    uint256 public constant BASIS_POINTS = 10000; // 100% = 10000 basis points

    // Payment configuration
    uint256 public defaultSlippageTolerance = 500; // 5% default slippage
    uint256 public maxSlippageTolerance = 2000; // 20% max slippage
    uint256 public protocolFee = 100; // 1% protocol fee

    // Payment tracking
    struct Payment {
        uint256 eventId;
        address payer;
        address originalToken;
        uint256 originalAmount;
        uint256 mneeAmount;
        address recipient;
        uint256 timestamp;
        string swapPath; // JSON string of the swap path
    }

    mapping(uint256 => Payment) public payments;
    mapping(address => bool) public supportedIntermediateTokens;
    mapping(address => bool) private intermediateTokenConfigured;
    uint256 public nextPaymentId;

    // Events
    event PaymentMade(
        uint256 indexed paymentId,
        uint256 indexed eventId,
        address indexed payer,
        address recipient,
        address originalToken,
        uint256 originalAmount,
        uint256 mneeAmount,
        string swapPath,
        uint256 timestamp
    );

    event TokenRegistered(address indexed token, bool supported);
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);

    // Errors
    error InsufficientOutput(uint256 required, uint256 received);
    error TokenNotSupported(address token);
    error InvalidSlippageTolerance(uint256 slippage);
    error PaymentAlreadyProcessed(uint256 paymentId);
    error InvalidAmount();
    error InvalidSwapPath();

    constructor(
        address _poolManager,
        address _mneeToken,
        address _swapHook,
        address _tokenRouter
    ) Ownable(msg.sender) {
        poolManager = IPoolManager(_poolManager);
        MNEE_TOKEN = _mneeToken;
        swapHook = MNEESwapHook(_swapHook);
        tokenRouter = TokenRouter(_tokenRouter);

        // Initialize with common intermediate tokens
        _initializeIntermediateTokens();
    }

    /**
     * @notice Main payment function - accepts any ERC20 token and converts to MNEE
     * @param eventId Event identifier for payment tracking
     * @param tokenIn Input ERC20 token address
     * @param amountIn Amount of input tokens
     * @param recipient Final recipient of MNEE tokens
     * @param minMNEEOut Minimum MNEE tokens to receive (slippage protection)
     * @param swapPath Precomputed swap path (off-chain routing)
     * @return paymentId Unique payment identifier
     * @return mneeAmount Amount of MNEE tokens received
     */
    function pay(
        uint256 eventId,
        address tokenIn,
        uint256 amountIn,
        address recipient,
        uint256 minMNEEOut,
        address[] calldata swapPath
    ) external nonReentrant returns (uint256 paymentId, uint256 mneeAmount) {
        if (amountIn == 0) revert InvalidAmount();
        if (minMNEEOut == 0) revert InvalidAmount();
        if (swapPath.length == 0) revert InvalidSwapPath();
        if (swapPath[0] != tokenIn) revert InvalidSwapPath();
        if (swapPath[swapPath.length - 1] != MNEE_TOKEN) revert InvalidSwapPath();

        paymentId = ++nextPaymentId;

        // Transfer tokens from payer to this contract
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        _validateSwapPath(swapPath);

        bool directMNEE = swapPath.length == 1 && swapPath[0] == MNEE_TOKEN && tokenIn == MNEE_TOKEN;

        // Calculate expected output with slippage
        uint256 expectedOutput = directMNEE
            ? amountIn
            : tokenRouter.calculateExpectedOutput(
                tokenIn,
                amountIn,
                swapPath
            );

        if (expectedOutput == 0) {
            revert InsufficientOutput(minMNEEOut, 0);
        }

        // Apply slippage tolerance
        uint256 minOutput = (expectedOutput * (BASIS_POINTS - defaultSlippageTolerance)) / BASIS_POINTS;
        if (minMNEEOut > minOutput) {
            minOutput = minMNEEOut;
        }

        if (directMNEE) {
            mneeAmount = amountIn;
        } else {
            mneeAmount = _executeSwap(tokenIn, amountIn, swapPath, minOutput);
        }

        // Check slippage protection
        if (mneeAmount < minOutput) {
            revert InsufficientOutput(minOutput, mneeAmount);
        }

        // Deduct protocol fee
        uint256 protocolFeeAmount = (mneeAmount * protocolFee) / BASIS_POINTS;
        if (protocolFeeAmount > 0) {
            IERC20(MNEE_TOKEN).safeTransfer(owner(), protocolFeeAmount);
            mneeAmount -= protocolFeeAmount;
        }

        // Transfer MNEE to recipient
        IERC20(MNEE_TOKEN).safeTransfer(recipient, mneeAmount);

        string memory serializedPath = _formatSwapPath(swapPath);

        // Record payment
        payments[paymentId] = Payment({
            eventId: eventId,
            payer: msg.sender,
            originalToken: tokenIn,
            originalAmount: amountIn,
            mneeAmount: mneeAmount,
            recipient: recipient,
            timestamp: block.timestamp,
            swapPath: serializedPath
        });

        emit PaymentMade(
            paymentId,
            eventId,
            msg.sender,
            recipient,
            tokenIn,
            amountIn,
            mneeAmount,
            serializedPath,
            block.timestamp
        );
    }

    /**
     * @notice Get payment quote without executing
     * @param tokenIn Input token address
     * @param amountIn Input amount
     * @param swapPath Precomputed path to evaluate
     * @return expectedMNEE Expected MNEE output
     */
    function getQuote(
        address tokenIn,
        uint256 amountIn,
        address[] calldata swapPath
    ) external view returns (uint256 expectedMNEE) {
        if (swapPath.length == 0) revert InvalidSwapPath();
        if (swapPath[0] != tokenIn) revert InvalidSwapPath();
        if (swapPath[swapPath.length - 1] != MNEE_TOKEN) revert InvalidSwapPath();

        _validateSwapPath(swapPath);
        expectedMNEE = tokenRouter.calculateExpectedOutput(tokenIn, amountIn, swapPath);
    }

    /**
     * @notice Check if a token is supported for payments
     * @param token Token address to check
     * @return isSupported Whether token is supported
     */
    function isTokenSupported(address token) external view returns (bool isSupported) {
        if (token == MNEE_TOKEN) return true;

        (bool registered,,,,,) = tokenRouter.tokenRegistry(token);
        return registered;
    }

    /**
     * @notice Update default slippage tolerance
     * @param newSlippage New slippage in basis points
     */
    function setDefaultSlippageTolerance(uint256 newSlippage) external onlyOwner {
        if (newSlippage > maxSlippageTolerance) {
            revert InvalidSlippageTolerance(newSlippage);
        }

        uint256 oldSlippage = defaultSlippageTolerance;
        defaultSlippageTolerance = newSlippage;
        emit SlippageUpdated(oldSlippage, newSlippage);
    }

    /**
     * @notice Update protocol fee
     * @param newFee New fee in basis points
     */
    function setProtocolFee(uint256 newFee) external onlyOwner {
        if (newFee > 1000) { // Max 10%
            revert InvalidSlippageTolerance(newFee);
        }

        uint256 oldFee = protocolFee;
        protocolFee = newFee;
        emit ProtocolFeeUpdated(oldFee, newFee);
    }

    /**
     * @notice Add/remove supported intermediate token
     * @param token Token address
     * @param supported Whether token is supported
     */
    function setSupportedIntermediateToken(address token, bool supported) external onlyOwner {
        supportedIntermediateTokens[token] = supported;
        intermediateTokenConfigured[token] = true;
        emit TokenRegistered(token, supported);
    }

    // Internal functions

    function _executeSwap(
        address tokenIn,
        uint256 amountIn,
        address[] memory swapPath,
        uint256 minOutput
    ) internal returns (uint256) {
        // Approve tokens to swap hook
        IERC20(tokenIn).safeIncreaseAllowance(address(swapHook), amountIn);

        if (swapPath.length <= 1) {
            return amountIn;
        }

        if (swapPath.length == 2) {
            // Direct swap
            return swapHook.swap(tokenIn, swapPath[1], amountIn, minOutput, address(this));
        } else {
            // Multihop swap
            return swapHook.multihopSwap(tokenIn, swapPath, amountIn, minOutput, address(this));
        }
    }

    function _formatSwapPath(address[] memory path) internal pure returns (string memory) {
        // Simple JSON array formatting for storage
        string memory result = "[";
        for (uint256 i = 0; i < path.length; i++) {
            if (i > 0) result = string(abi.encodePacked(result, ","));
            result = string(abi.encodePacked(result, "\"", _addressToString(path[i]), "\""));
        }
        return string(abi.encodePacked(result, "]"));
    }

    function _validateSwapPath(address[] memory path) internal view {
        if (path.length == 0) revert InvalidSwapPath();

        if (path.length > 1 && !tokenRouter.validatePath(path)) {
            revert InvalidSwapPath();
        }

        if (path.length <= 2) return;
        for (uint256 i = 1; i < path.length - 1; i++) {
            address token = path[i];
            if (intermediateTokenConfigured[token] && !supportedIntermediateTokens[token]) {
                revert TokenNotSupported(token);
            }
        }
    }

    function _addressToString(address addr) internal pure returns (string memory) {
        bytes32 value = bytes32(uint256(uint160(addr)));
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i + 12] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i + 12] & 0x0f)];
        }
        return string(str);
    }

    function _initializeIntermediateTokens() internal {
        // Common intermediate tokens - these should be configured based on actual deployment
        // Default allowlist is opt-in and starts empty. Owner can configure tokens later.
    }
}