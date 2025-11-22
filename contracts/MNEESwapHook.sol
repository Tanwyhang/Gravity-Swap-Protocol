// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MNEESwapHook
 * @notice Hook-style swap helper that bridges GravityPayment to Uniswap v4 style routing
 */
contract MNEESwapHook is IHooks, Ownable {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Core dependencies
    IPoolManager public immutable poolManager;
    PoolSwapTest public immutable poolSwapTest;
    address public immutable MNEE_TOKEN;

    // Access control
    address public tokenRouter;

    // Token whitelist
    mapping(address => bool) public allowedTokens;

    // Fee configuration (hundredths of a bip)
    uint24 public swapFee = 100;
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public hopSlippageToleranceBps = 1000; // 10% default per-hop tolerance

    // Events
    event TokenSwap(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient
    );

    event TokenRegistered(address indexed token, bool allowed);
    event TokenRouterUpdated(address indexed router);
    event SwapFeeUpdated(uint256 oldFee, uint256 newFee);
    event HopSlippageToleranceUpdated(uint256 oldValue, uint256 newValue);

    constructor(address _poolManager, address _mneeToken) Ownable(msg.sender) {
        poolManager = IPoolManager(_poolManager);
        poolSwapTest = new PoolSwapTest(poolManager);
        MNEE_TOKEN = _mneeToken;

        // Default supported assets (USDC + common majors)
        allowedTokens[0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = true; // USDC
        allowedTokens[0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2] = true; // WETH
        allowedTokens[0x6B175474E89094C44Da98b954EedeAC495271d0F] = true; // DAI
        allowedTokens[0xdAC17F958D2ee523a2206206994597C13D831ec7] = true; // USDT
        allowedTokens[_mneeToken] = true; // Always allow MNEE
    }

    function registerToken(address token, bool allowed) external {
        require(msg.sender == owner() || msg.sender == tokenRouter, "Unauthorized");
        allowedTokens[token] = allowed;
        emit TokenRegistered(token, allowed);
    }

    function setTokenRouter(address _tokenRouter) external onlyOwner {
        require(_tokenRouter != address(0), "Invalid router");
        tokenRouter = _tokenRouter;
        emit TokenRouterUpdated(_tokenRouter);
    }

    function setSwapFee(uint24 newFee) external onlyOwner {
        require(newFee > 0, "Invalid fee");
        uint256 oldFee = swapFee;
        swapFee = newFee;
        emit SwapFeeUpdated(oldFee, newFee);
    }

    function setHopSlippageTolerance(uint256 newToleranceBps) external onlyOwner {
        require(newToleranceBps < BASIS_POINTS, "Invalid tolerance");
        uint256 oldValue = hopSlippageToleranceBps;
        hopSlippageToleranceBps = newToleranceBps;
        emit HopSlippageToleranceUpdated(oldValue, newToleranceBps);
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient
    ) public returns (uint256 amountOut) {
        require(allowedTokens[tokenIn], "Token not allowed");
        require(allowedTokens[tokenOut], "Token not allowed");
        require(amountIn > 0, "Invalid amount");

        amountOut = _executeSwap(
            tokenIn,
            tokenOut,
            amountIn,
            amountOutMin,
            recipient,
            true,
            msg.sender
        );
    }

    function swapToMNEE(
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient
    ) external returns (uint256 amountOut) {
        return swap(tokenIn, MNEE_TOKEN, amountIn, amountOutMin, recipient);
    }

    function multihopSwap(
        address tokenIn,
        address[] memory path,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient
    ) external returns (uint256 amountOut) {
        require(path.length >= 2, "Invalid path length");
        require(path[0] == tokenIn, "Path must start with tokenIn");
        require(amountIn > 0, "Invalid amount");

        // Pull tokens once; internal hops reuse contract balance
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 currentAmount = amountIn;
        for (uint256 i = 0; i < path.length - 1; i++) {
            address fromToken = path[i];
            address toToken = path[i + 1];
            require(allowedTokens[fromToken], "Token not allowed");
            require(allowedTokens[toToken], "Token not allowed");

            bool isLastHop = (i == path.length - 2);
            uint256 hopMinOut = isLastHop ? amountOutMin : _minHopOutput(currentAmount);
            address hopRecipient = isLastHop ? recipient : address(this);

            currentAmount = _executeSwap(
                fromToken,
                toToken,
                currentAmount,
                hopMinOut,
                hopRecipient,
                false,
                address(this)
            );
        }

        amountOut = currentAmount;
    }

    function _executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        bool pullFromSender,
        address payer
    ) internal returns (uint256 amountOut) {
        if (pullFromSender) {
            IERC20(tokenIn).safeTransferFrom(payer, address(this), amountIn);
        }

        PoolKey memory poolKey = _createPoolKey(tokenIn, tokenOut);
        bool zeroForOne = tokenIn < tokenOut;
        uint160 sqrtPriceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountIn),
            sqrtPriceLimitX96: sqrtPriceLimit
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        BalanceDelta delta = poolSwapTest.swap(poolKey, swapParams, testSettings, "");
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        int256 signedAmountOut = zeroForOne ? -int256(delta1) : -int256(delta0);
        require(signedAmountOut > 0, "No output");

        amountOut = uint256(signedAmountOut);
        require(amountOut >= amountOutMin, "Insufficient output amount");

        if (recipient != address(this)) {
            IERC20(tokenOut).safeTransfer(recipient, amountOut);
        }

        emit TokenSwap(tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    function _createPoolKey(address tokenA, address tokenB) internal view returns (PoolKey memory) {
        (Currency currency0, Currency currency1) = tokenA < tokenB
            ? (Currency.wrap(tokenA), Currency.wrap(tokenB))
            : (Currency.wrap(tokenB), Currency.wrap(tokenA));

        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: swapFee,
            tickSpacing: 60,
            hooks: this
        });
    }

    function _minHopOutput(uint256 amountIn) internal view returns (uint256) {
        uint256 minOut = (amountIn * (BASIS_POINTS - hopSlippageToleranceBps)) / BASIS_POINTS;
        return minOut == 0 ? 1 : minOut;
    }

    // Hook stubs required by IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        bytes calldata
    ) external pure returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, int128(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}
