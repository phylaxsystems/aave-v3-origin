// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DataTypes} from "../../src/contracts/protocol/libraries/types/DataTypes.sol";
import {IPriceOracleGetter} from "../../src/contracts/interfaces/IPriceOracleGetter.sol";

interface IMockPool {
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
    function getReserveData(address asset) external view returns (DataTypes.ReserveDataLegacy memory);
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getUserConfiguration(address user) external view returns (DataTypes.UserConfigurationMap memory);

    // Reserve state control functions
    function setReserveActive(address asset, bool active) external;
    function setReserveFrozen(address asset, bool frozen) external;
    function setReservePaused(address asset, bool isPaused) external;

    // New functions for liquidation assertions
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;
    function getCloseFactor() external view returns (uint256);
    function MIN_BASE_MAX_CLOSE_FACTOR_THRESHOLD() external view returns (uint256);
    function MIN_LEFTOVER_BASE() external view returns (uint256);
    function getUserCollateralBalance(address user, address asset) external view returns (uint256);
    function getUserDebtBalance(address user, address asset) external view returns (uint256);
    function getReserveDeficit(address asset) external view returns (uint256);
    function getLiquidationGracePeriod(address asset) external view returns (uint40);

    // Flashloan function
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;

    // Simple flashloan function
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}
