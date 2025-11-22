// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/**
 * @title MockPoolManager
 * @notice Mock implementation of Uniswap v4 Pool Manager for testing and development
 * @dev Simulates Uniswap v4 Pool Manager behavior without actual on-chain liquidity or AMM logic
 *
 * Features:
 * - Mock exchange rate configuration for testing swap scenarios
 * - Simulated pool state (slot0) management
 * - Settle and take functionality for token transfers
 * - Liquidity and price queries
 * - Position management mocking
 *
 * Core Functionality:
 * - Exchange rate setting and querying
 * - Mock swap execution with configurable rates
 * - Pool state management (sqrtPriceX96, tick, fees)
 * - Token balance tracking for simulation
 * - Event emission for testing event listeners
 *
 * Use Cases:
 * - Testing Uniswap v4 integrations without mainnet deployment
 * - Development of swap contracts and scripts
 * - Unit testing with controlled swap scenarios
 * - Gas estimation and optimization
 * - Simulating various market conditions
 *
 * Mock Logic:
 * - Simplified exchange rate calculations
 * - No actual AMM curves or liquidity dynamics
 * - Configurable exchange rates for deterministic testing
 * - Token balance tracking instead of actual transfers
 *
 * Security:
 * - FOR TESTING PURPOSES ONLY
 * - No real value or liquidity at stake
 * - Mock implementations of critical functions
 *
 * Dependencies:
 * - Uniswap v4 Core interfaces and types
 */
contract MockPoolManager {
    mapping(address => mapping(address => uint256)) public mockExchangeRates;
    mapping(address => uint256) public tokenBalances;

    struct MockSlot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 protocolFee;
        uint16 lpFee;
    }

    mapping(PoolId => MockSlot0) public mockSlot0Data;

    event Swap(
        PoolId indexed poolId,
        address indexed sender,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint24 liquidity,
        int24 tick,
        uint128 protocolFee,
        uint256 logFee
    );

    function setMockExchangeRate(
        address tokenIn,
        address tokenOut,
        uint256 rate // Rate in basis points (10000 = 100%)
    ) external {
        mockExchangeRates[tokenIn][tokenOut] = rate;
        mockExchangeRates[tokenOut][tokenIn] = 10000 * 10000 / rate; // Inverse rate with higher precision
    }

    function getMockExchangeRate(address tokenIn, address tokenOut) external view returns (uint256) {
        return mockExchangeRates[tokenIn][tokenOut];
    }

    function settle(address currency) external payable {
        // Mock settle - just add to balance
        if (msg.value > 0) {
            tokenBalances[address(0)] += msg.value;
        } else {
            // For ERC20 tokens, the transfer should have already happened
            tokenBalances[currency] += msg.value; // This is simplified
        }
    }

    function take(address currency, address /* to */, uint256 amount) external {
        require(tokenBalances[currency] >= amount, "Insufficient balance");
        tokenBalances[currency] -= amount;

        // Mock transfer - in real implementation this would actually transfer tokens
        // For testing, we just track the balance
    }

    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimit
    ) external returns (int256) {
        // Simplified mock swap logic
        address tokenIn = Currency.unwrap(key.currency0);
        address tokenOut = Currency.unwrap(key.currency1);

        if (!zeroForOne) {
            // Swap direction is reversed
            (tokenIn, tokenOut) = (tokenOut, tokenIn);
        }

        uint256 rate = mockExchangeRates[tokenIn][tokenOut];
        require(rate > 0, "No exchange rate set");

        require(amountSpecified >= 0, "Exact output unsupported");
        uint256 inputAmount = uint256(amountSpecified);

        // Calculate output amount based on mock rate
        uint256 outputAmount = (inputAmount * rate) / 10000;

        // Update mock slot0
        PoolId poolId = PoolId.wrap(keccak256(abi.encode(key)));
        mockSlot0Data[poolId] = MockSlot0({
            sqrtPriceX96: uint160(sqrtPriceLimit),
            tick: 0,
            protocolFee: 0,
            lpFee: 3000
        });

        emit Swap(
            poolId,
            msg.sender,
            zeroForOne ? amountSpecified : -int256(outputAmount),
            zeroForOne ? int256(outputAmount) : -amountSpecified,
            sqrtPriceLimit,
            0,
            0,
            0,
            0
        );

        return -int256(outputAmount); // Return negative amount for output
    }

    function getLiquidity(PoolId /* id */) external pure returns (uint128) {
        return 1000000; // Mock liquidity
    }

    function getSlot0(PoolId id) external view returns (uint160 sqrtPriceX96, int24 tick, uint16 protocolFee, uint16 lpFee) {
        MockSlot0 memory slot0 = mockSlot0Data[id];
        if (slot0.sqrtPriceX96 == 0) {
            // Default values if not set
            return (uint160(1 << 96), 0, 0, 3000); // Price of 1, tick 0, no protocol fees, 0.3% LP fee
        }
        return (slot0.sqrtPriceX96, slot0.tick, slot0.protocolFee, slot0.lpFee);
    }

    function setMockSlot0(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 protocolFee,
        uint16 lpFee
    ) external {
        PoolId poolId = PoolId.wrap(keccak256(abi.encode(key)));
        mockSlot0Data[poolId] = MockSlot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            protocolFee: protocolFee,
            lpFee: lpFee
        });
    }

    // Mock functions for other PoolManager operations
    function modifyPosition(
        PoolKey calldata /* key */,
        ModifyLiquidityParams calldata /* params */
    ) external pure returns (BalanceDelta) {
        // Mock position modification
        return BalanceDelta.wrap(0);
    }

    function donate(
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1
    ) external {
        // Mock donation
    }
}