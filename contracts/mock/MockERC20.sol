// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockERC20
 * @notice Mock ERC20 token contract for testing and development purposes
 * @dev Extends OpenZeppelin's ERC20 with additional testing utilities
 *
 * Features:
 * - Standard ERC20 token implementation (via OpenZeppelin)
 * - Configurable name, symbol, and decimals
 * - Mint function for token creation
 * - Burn function for token destruction
 * - Flexible decimal configuration (supports tokens like USDC with 6 decimals)
 *
 * Use Cases:
 * - Testing DeFi protocols and swap functionality
 * - Development environment token simulation
 * - Unit testing with controlled token supplies
 * - Mocking real tokens for integration tests
 * - Gas estimation and performance testing
 *
 * Security:
 * - Inherits security features from OpenZeppelin ERC20
 * - Mint/burn functions are unrestricted (TESTING ONLY)
 * - Should NOT be used in production environments
 *
 * Dependencies:
 * - OpenZeppelin Contracts v5.x
 */
contract MockERC20 is ERC20, Ownable {
    uint8 private _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimalsValue
    ) ERC20(name, symbol) Ownable(msg.sender) {
        _decimals = decimalsValue;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != from && msg.sender != owner()) {
            _spendAllowance(from, msg.sender, amount);
        }
        _burn(from, amount);
    }
}