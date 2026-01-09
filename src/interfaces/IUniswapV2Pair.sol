// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IUniswapV2Pair
 * @notice Minimal interface for Uniswap V2 pair token queries
 */
interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
}
