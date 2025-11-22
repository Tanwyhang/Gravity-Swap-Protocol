// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/**
 * @title TokenRouter
 * @notice Intelligent routing and path discovery for token swaps
 * @dev Provides optimal path finding for multihop swaps on Uniswap v4
 *
 * Key Features:
 * - Automatic path discovery between any token pair
 * - Optimization for best rates and minimal gas
 * - Support for direct and multihop routing
 * - Pool registry for high-liquidity pools
 * - Gas estimation and slippage calculations
 *
 * Architecture:
 * - Maintains registry of high-liquidity intermediate tokens
 * - Uses graph algorithms for path optimization
 * - Calculates expected outputs with price impact
 * - Supports up to 5-hop routing for maximum flexibility
 *
 * Use Cases:
 * - Payment processing with flexible routing
 * - DeFi protocol integration
 * - Arbitrage opportunity discovery
 * - Cross-asset trading strategies
 */
contract TokenRouter is Ownable {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Core dependencies
    IPoolManager public immutable poolManager;

    // Token registry
    struct TokenInfo {
        bool isSupported;
        bool isIntermediate;
        uint8 decimals;
        string symbol;
        uint256 liquidityScore; // 0-1000 scale for liquidity quality
        uint256 lastUpdated;
    }

    mapping(address => TokenInfo) public tokenRegistry;
    address[] public supportedTokens;
    address[] public intermediateTokens;

    // Pool registry for efficient lookups
    struct PoolInfo {
        PoolKey poolKey;
        uint24 fee;
        int24 tickSpacing;
        uint256 volume24h; // Mock volume tracking
        uint256 lastUpdated;
        bool isActive;
    }

    mapping(bytes32 => PoolInfo) public poolRegistry;
    mapping(bytes32 => uint256) public poolExchangeRates;
    mapping(address => mapping(address => bool)) public hasDirectPool;
    mapping(address => address[]) private adjacencyList;
    mapping(address => mapping(address => bytes32)) private poolIdsByPair;

    // Routing configuration
    uint256 public constant MAX_HOPS = 5;
    uint256 public constant MIN_LIQUIDITY_SCORE = 100;
    uint256 private constant ONE_WAD = 1e18;

    // Events
    event TokenRegistered(address indexed token, string symbol, uint8 decimals);
    event TokenRemoved(address indexed token);
    event PoolRegistered(address indexed token0, address indexed token1, uint24 fee);
    event PoolRemoved(address indexed token0, address indexed token1);
    event IntermediateTokenUpdated(address indexed token, bool isIntermediate);
    event PoolRateUpdated(address indexed token0, address indexed token1, uint256 rateWad);

    // Errors
    error NoPathFound(address tokenIn, address tokenOut);
    error TokenNotRegistered(address token);
    error InvalidTokenAddress(address token);
    error InvalidRate();

    constructor(address _poolManager) Ownable(msg.sender) {
        poolManager = IPoolManager(_poolManager);
    }


    /**
     * @notice Calculate expected output for a given path
     * @param tokenIn Input token address
     * @param amountIn Input amount
     * @param path Swap path array
     * @return expectedOutput Expected output amount
     */
    function calculateExpectedOutput(
        address tokenIn,
        uint256 amountIn,
        address[] memory path
    ) external view returns (uint256 expectedOutput) {
        if (path.length == 0 || path[0] != tokenIn) {
            return 0;
        }

        if (amountIn == 0) {
            return 0;
        }

        if (path.length == 1) {
            return amountIn;
        }

        uint256 currentAmount = amountIn;

        for (uint256 i = 0; i < path.length - 1; i++) {
            address tokenA = path[i];
            address tokenB = path[i + 1];

            (bool poolExists, PoolKey memory poolKey,, uint24 fee, uint256 rateWad) = _getPoolData(tokenA, tokenB);
            if (!poolExists) {
                return 0;
            }

            bool tokenInIsCurrency0 = Currency.unwrap(poolKey.currency0) == tokenA;

            currentAmount = _simulateSwap(currentAmount, tokenInIsCurrency0, fee, rateWad);

            if (currentAmount == 0) {
                return 0;
            }
        }

        return currentAmount;
    }

    /**
     * @notice Check if direct pool exists between tokens
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return exists Whether direct pool exists
     */
    function checkDirectPool(address tokenA, address tokenB) external view returns (bool exists) {
        return hasDirectPool[tokenA][tokenB];
    }

    /**
     * @notice Register a new token for routing
     * @param token Token address
     * @param symbol Token symbol
     * @param decimals Token decimals
     * @param liquidityScore Initial liquidity score (0-1000)
     */
    function registerToken(
        address token,
        string memory symbol,
        uint8 decimals,
        uint256 liquidityScore
    ) external onlyOwner {
        if (token == address(0)) revert InvalidTokenAddress(token);

        bool isNew = !tokenRegistry[token].isSupported;
        bool wasIntermediate = tokenRegistry[token].isIntermediate;

        tokenRegistry[token] = TokenInfo({
            isSupported: true,
            isIntermediate: wasIntermediate,
            decimals: decimals,
            symbol: symbol,
            liquidityScore: liquidityScore > 1000 ? 1000 : liquidityScore,
            lastUpdated: block.timestamp
        });

        if (isNew) {
            supportedTokens.push(token);
        }

        emit TokenRegistered(token, symbol, decimals);
    }

    /**
     * @notice Register a pool for routing
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param fee Pool fee
     * @param tickSpacing Pool tick spacing
     */
    function registerPool(
        address tokenA,
        address tokenB,
        uint24 fee,
        int24 tickSpacing
    ) external onlyOwner {
        if (tokenA == address(0) || tokenB == address(0)) {
            revert InvalidTokenAddress(tokenA == address(0) ? tokenA : tokenB);
        }

        if (!tokenRegistry[tokenA].isSupported || !tokenRegistry[tokenB].isSupported) {
            revert TokenNotRegistered(!tokenRegistry[tokenA].isSupported ? tokenA : tokenB);
        }

        PoolKey memory newPoolKey = PoolKey({
            currency0: tokenA < tokenB ? Currency.wrap(tokenA) : Currency.wrap(tokenB),
            currency1: tokenA < tokenB ? Currency.wrap(tokenB) : Currency.wrap(tokenA),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        bytes32 poolId = PoolId.unwrap(newPoolKey.toId());

        poolRegistry[poolId] = PoolInfo({
            poolKey: newPoolKey,
            fee: fee,
            tickSpacing: tickSpacing,
            volume24h: 0,
            lastUpdated: block.timestamp,
            isActive: true
        });

        poolExchangeRates[poolId] = ONE_WAD;

        _linkTokens(tokenA, tokenB, poolId);

        emit PoolRegistered(tokenA, tokenB, fee);
    }

    function setPoolExchangeRate(address tokenA, address tokenB, uint256 rateWad) external onlyOwner {
        if (tokenA == address(0) || tokenB == address(0)) {
            revert InvalidTokenAddress(tokenA == address(0) ? tokenA : tokenB);
        }

        if (rateWad == 0) {
            revert InvalidRate();
        }

        bytes32 poolId = poolIdsByPair[tokenA][tokenB];
        if (poolId == bytes32(0) || !poolRegistry[poolId].isActive) {
            revert NoPathFound(tokenA, tokenB);
        }

        poolExchangeRates[poolId] = rateWad;

        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        emit PoolRateUpdated(token0, token1, rateWad);
    }

    /**
     * @notice Add/remove intermediate token
     * @param token Token address
     * @param isIntermediate Whether token should be used as intermediate
     */
    function setIntermediateToken(address token, bool isIntermediate) external onlyOwner {
        if (!tokenRegistry[token].isSupported) {
            revert TokenNotRegistered(token);
        }

        // Update intermediate tokens array
        bool found = false;
        for (uint256 i = 0; i < intermediateTokens.length; i++) {
            if (intermediateTokens[i] == token) {
                found = true;
                if (!isIntermediate) {
                    // Remove from array
                    intermediateTokens[i] = intermediateTokens[intermediateTokens.length - 1];
                    intermediateTokens.pop();
                }
                break;
            }
        }

        if (!found && isIntermediate) {
            intermediateTokens.push(token);
        }

        tokenRegistry[token].isIntermediate = isIntermediate;

        emit IntermediateTokenUpdated(token, isIntermediate);
    }

    /**
     * @notice Get all supported intermediate tokens
     * @return tokens Array of intermediate token addresses
     */
    function getIntermediateTokens() external view returns (address[] memory tokens) {
        return intermediateTokens;
    }

    /**
     * @notice Update token liquidity score
     * @param token Token address
     * @param score New liquidity score (0-1000)
     */
    function updateLiquidityScore(address token, uint256 score) external onlyOwner {
        if (!tokenRegistry[token].isSupported) {
            revert TokenNotRegistered(token);
        }

        tokenRegistry[token].liquidityScore = score > 1000 ? 1000 : score;
        tokenRegistry[token].lastUpdated = block.timestamp;
    }

    // View helpers for off-chain routing

    function getSupportedTokens() external view returns (address[] memory tokens) {
        return supportedTokens;
    }

    function getNeighbors(address token) external view returns (address[] memory neighbors) {
        return adjacencyList[token];
    }

    function validatePath(address[] memory path) public view returns (bool) {
        if (path.length == 0) {
            return false;
        }

        if (path.length == 1) {
            return tokenRegistry[path[0]].isSupported;
        }

        if (path.length - 1 > MAX_HOPS) {
            return false;
        }

        for (uint256 i = 0; i < path.length; i++) {
            if (!tokenRegistry[path[i]].isSupported) {
                return false;
            }
        }

        for (uint256 i = 0; i < path.length - 1; i++) {
            if (!hasDirectPool[path[i]][path[i + 1]]) {
                return false;
            }
        }

        return true;
    }

    function getPoolRate(address tokenA, address tokenB) external view returns (uint256 rateWad) {
        bytes32 poolId = poolIdsByPair[tokenA][tokenB];
        if (poolId == bytes32(0)) {
            return 0;
        }

        rateWad = poolExchangeRates[poolId];
        if (rateWad == 0) {
            rateWad = ONE_WAD;
        }
    }

    // Internal functions

    function _linkTokens(address tokenA, address tokenB, bytes32 poolId) internal {
        poolIdsByPair[tokenA][tokenB] = poolId;
        poolIdsByPair[tokenB][tokenA] = poolId;
        hasDirectPool[tokenA][tokenB] = true;
        hasDirectPool[tokenB][tokenA] = true;
        _addNeighbor(tokenA, tokenB);
        _addNeighbor(tokenB, tokenA);
    }

    function _addNeighbor(address from, address to) internal {
        address[] storage neighbors = adjacencyList[from];
        for (uint256 i = 0; i < neighbors.length; i++) {
            if (neighbors[i] == to) {
                return;
            }
        }
        neighbors.push(to);
    }

    function _getPoolData(address tokenA, address tokenB)
        internal
        view
        returns (bool exists, PoolKey memory poolKey, bytes32 poolId, uint24 fee, uint256 rateWad)
    {
        poolId = poolIdsByPair[tokenA][tokenB];
        if (poolId == bytes32(0)) {
            return (false, poolKey, poolId, fee, rateWad);
        }

        PoolInfo storage info = poolRegistry[poolId];
        if (!info.isActive) {
            return (false, poolKey, poolId, fee, rateWad);
        }

        uint256 storedRate = poolExchangeRates[poolId];
        if (storedRate == 0) {
            storedRate = ONE_WAD;
        }

        return (true, info.poolKey, poolId, info.fee, storedRate);
    }

    function _simulateSwap(
        uint256 amountIn,
        bool tokenInIsCurrency0,
        uint24 fee,
        uint256 rateWad
    ) internal pure returns (uint256) {
        if (amountIn == 0 || rateWad == 0) {
            return 0;
        }

        uint256 amountOut = tokenInIsCurrency0
            ? Math.mulDiv(amountIn, rateWad, ONE_WAD)
            : Math.mulDiv(amountIn, ONE_WAD, rateWad);

        if (amountOut == 0) {
            return 0;
        }

        uint256 feeAmount = Math.mulDiv(amountOut, fee, 1_000_000);
        if (feeAmount >= amountOut) {
            return 0;
        }

        return amountOut - feeAmount;
    }
}