// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DataTypes} from "../../src/contracts/protocol/libraries/types/DataTypes.sol";

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
}
