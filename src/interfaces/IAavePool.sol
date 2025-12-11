// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAavePool
 * @notice Minimal interface for Aave V3 Pool to get reserve data
 */
interface IAavePool {
    struct ReserveData {
        // Stores the reserve configuration
        uint256 configuration;
        // Liquidity index. Expressed in ray
        uint128 liquidityIndex;
        // Current supply rate. Expressed in ray
        uint128 currentLiquidityRate;
        // Variable borrow index. Expressed in ray
        uint128 variableBorrowIndex;
        // Current variable borrow rate. Expressed in ray
        uint128 currentVariableBorrowRate;
        // Current stable borrow rate. Expressed in ray
        uint128 currentStableBorrowRate;
        // Timestamp of last update
        uint40 lastUpdateTimestamp;
        // Id of the reserve
        uint16 id;
        // aToken address
        address aTokenAddress;
        // stableDebtToken address
        address stableDebtTokenAddress;
        // variableDebtToken address
        address variableDebtTokenAddress;
        // Address of the interest rate strategy
        address interestRateStrategyAddress;
        // Accrued to treasury
        uint128 accruedToTreasury;
        // Unbacked amount outstanding
        uint128 unbacked;
        // Isolation mode total debt
        uint128 isolationModeTotalDebt;
    }

    /**
     * @notice Returns the state and configuration of the reserve
     * @param asset The address of the underlying asset of the reserve
     * @return The state and configuration data of the reserve
     */
    function getReserveData(address asset) external view returns (ReserveData memory);
}
