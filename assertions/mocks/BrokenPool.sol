// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DataTypes} from "../../src/contracts/protocol/libraries/types/DataTypes.sol";
import {IERC20} from "../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import {IMockPool} from "../src/IMockPool.sol";

contract BrokenPool is IMockPool {
    // Store user debt amounts
    mapping(address => uint256) public userDebt;

    // Store user balances
    mapping(address => mapping(address => uint256)) public userBalances;

    // Store health factors
    mapping(address => uint256) public userHealthFactors;

    // Store aToken addresses
    mapping(address => address) public aTokenAddresses;

    // Configuration flags
    bool public breakDepositBalance;
    bool public breakRepayDebt;
    bool public breakWithdrawBalance;
    bool public breakFlashloanRepayment;

    // Simple state tracking
    mapping(address => bool) public isActive;
    mapping(address => bool) public isFrozen;
    mapping(address => bool) public isPaused;

    // Liquidation state
    mapping(address => uint40) public liquidationGracePeriods;
    mapping(address => uint256) public reserveDeficits;

    function setATokenAddress(address asset, address aToken) external {
        aTokenAddresses[asset] = aToken;
    }

    function setUserDebt(address user, uint256 amount) external {
        userDebt[user] = amount;
    }

    function setBreakDepositBalance(bool value) external {
        breakDepositBalance = value;
    }

    function setBreakRepayDebt(bool value) external {
        breakRepayDebt = value;
    }

    function setBreakWithdrawBalance(bool value) external {
        breakWithdrawBalance = value;
    }

    function setBreakFlashloanRepayment(bool value) external {
        breakFlashloanRepayment = value;
    }

    function setUserHealthFactor(address user, uint256 healthFactor) external {
        userHealthFactors[user] = healthFactor;
    }

    // Simple state control functions
    function setReserveActive(address asset, bool active) external override {
        isActive[asset] = active;
    }

    function setReserveFrozen(address asset, bool frozen) external override {
        isFrozen[asset] = frozen;
    }

    function setReservePaused(address asset, bool paused) external override {
        isPaused[asset] = paused;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external override {
        if (!breakDepositBalance) {
            // Normal behavior - update balances
            userBalances[onBehalfOf][asset] += amount;
        }
        // If breakDepositBalance is true, don't update balances to violate the assertion
    }

    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        override
        returns (uint256)
    {
        if (!breakRepayDebt) {
            // Normal behavior - decrease debt
            userDebt[onBehalfOf] -= amount;
        }
        // If breakRepayDebt is true, don't decrease debt to violate the assertion
        return amount;
    }

    function getUserAccountData(address user)
        external
        view
        override
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        return (0, userDebt[user], 0, 0, 0, userHealthFactors[user]);
    }

    function getReserveData(address asset) external view override returns (DataTypes.ReserveDataLegacy memory) {
        DataTypes.ReserveDataLegacy memory data;
        // Create a simple configuration that matches our state
        data.configuration.data = 0;
        if (isActive[asset]) {
            data.configuration.data |= 1 << 56; // ACTIVE_MASK position
        }
        if (isFrozen[asset]) {
            data.configuration.data |= 1 << 57; // FROZEN_MASK position
        }
        if (isPaused[asset]) {
            data.configuration.data |= 1 << 60; // PAUSED_MASK position
        }
        return data;
    }

    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external
        override
    {
        // No-op for testing
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        if (!breakWithdrawBalance) {
            // Normal behavior - update balances
            userBalances[msg.sender][asset] -= amount;
        }
        return amount;
    }

    // Required IPool interface functions - return empty/default values
    function initReserve(
        address asset,
        address aTokenAddress,
        address stableDebtAddress,
        address variableDebtAddress,
        address interestRateStrategyAddress
    ) external {}

    function dropReserve(address asset) external {}

    function setReserveInterestRateStrategyAddress(address asset, address rateStrategyAddress) external {}

    function setConfiguration(address asset, DataTypes.ReserveConfigurationMap calldata configuration) external {}

    function getConfiguration(address asset) external pure returns (DataTypes.ReserveConfigurationMap memory) {
        return DataTypes.ReserveConfigurationMap(0);
    }

    function getUserConfiguration(address user)
        external
        view
        override
        returns (DataTypes.UserConfigurationMap memory)
    {
        return DataTypes.UserConfigurationMap(0);
    }

    function getReserveNormalizedIncome(address asset) external pure returns (uint256) {
        return 1e27;
    }

    function getReserveNormalizedVariableDebt(address asset) external pure returns (uint256) {
        return 1e27;
    }

    function finalizeTransfer(
        address asset,
        address from,
        address to,
        uint256 amount,
        uint256 balanceFromBefore,
        uint256 balanceToBefore
    ) external {}

    function getReservesList() external pure returns (address[] memory) {
        return new address[](0);
    }

    function getAddressesProvider() external pure returns (address) {
        return address(0);
    }

    function setPause(bool val) external {}

    function paused() external pure returns (bool) {
        return false;
    }

    // New functions for liquidation assertions
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external override {
        // No-op for testing
    }

    function getCloseFactor() external pure override returns (uint256) {
        return 5000; // 50%
    }

    function MIN_BASE_MAX_CLOSE_FACTOR_THRESHOLD() external pure override returns (uint256) {
        return 1000e18;
    }

    function MIN_LEFTOVER_BASE() external pure override returns (uint256) {
        return 100e18;
    }

    function getUserCollateralBalance(address user, address asset) external view override returns (uint256) {
        return userBalances[user][asset];
    }

    function getUserDebtBalance(address user, address asset) external view override returns (uint256) {
        return userDebt[user];
    }

    function getReserveDeficit(address asset) external view override returns (uint256) {
        return reserveDeficits[asset];
    }

    function getLiquidationGracePeriod(address asset) external view override returns (uint40) {
        return liquidationGracePeriods[asset];
    }

    // Helper functions for testing
    function setLiquidationGracePeriod(address asset, uint40 until) external {
        liquidationGracePeriods[asset] = until;
    }

    function setReserveDeficit(address asset, uint256 deficit) external {
        reserveDeficits[asset] = deficit;
    }

    // Flashloan implementation that can be broken
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external override {
        if (breakFlashloanRepayment) {
            // Broken behavior: Transfer tokens but don't require repayment
            for (uint256 i = 0; i < assets.length; i++) {
                IERC20(assets[i]).transfer(receiverAddress, amounts[i]);
            }
        }
        // Not broken behavior: Do nothing, pretending no state has changed
    }

    // Simple flashloan implementation that can be broken
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external override {
        if (breakFlashloanRepayment) {
            // Broken behavior: Transfer tokens but don't require repayment
            IERC20(asset).transfer(receiverAddress, amount);
        }
        // Not broken behavior: Do nothing, pretending no state has changed
    }
}
