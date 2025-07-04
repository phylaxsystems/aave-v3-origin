// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {IMockL2Pool} from '../src/interfaces/IMockL2Pool.sol';

contract BrokenPool is IMockL2Pool {
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
  function setReserveActive(address asset, bool active) external {
    isActive[asset] = active;
  }

  function setReserveFrozen(address asset, bool frozen) external {
    isFrozen[asset] = frozen;
  }

  function setReservePaused(address asset, bool paused) external {
    isPaused[asset] = paused;
  }

  function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
    if (!breakDepositBalance) {
      // Normal behavior - update balances
      userBalances[onBehalfOf][asset] += amount;
    } else {
      // Broken behavior: update balance but with wrong amount (off by 1 wei)
      userBalances[onBehalfOf][asset] += amount - 1;
    }
  }

  function repay(address, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
    if (!breakRepayDebt) {
      // Normal behavior - decrease debt
      userDebt[onBehalfOf] -= amount;
    } else {
      // Broken behavior: decrease debt but by wrong amount (off by 1 wei)
      userDebt[onBehalfOf] -= amount - 1;
    }
    return amount;
  }

  function getUserAccountData(
    address user
  )
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

  function getReserveData(
    address asset
  ) external view returns (DataTypes.ReserveDataLegacy memory) {
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

  function borrow(address, uint256 amount, uint256, uint16, address onBehalfOf) external {
    // Specific bug: when borrowing exactly 333e6, double the amount
    if (amount == 333e6) {
      userDebt[onBehalfOf] += amount * 2; // Double the debt
    } else {
      userDebt[onBehalfOf] += amount; // Normal behavior
    }
  }

  function withdraw(address asset, uint256 amount, address) external returns (uint256) {
    if (!breakWithdrawBalance) {
      // Normal behavior - update balances
      userBalances[msg.sender][asset] -= amount;
    } else {
      // Broken behavior: update balance but with wrong amount (off by 1 wei)
      userBalances[msg.sender][asset] -= amount - 1;
    }
    return amount;
  }

  // L2Pool function implementations
  function supply(bytes32 args) external {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // Broken behavior: update balance but with wrong amount (off by 1 wei)
    userBalances[msg.sender][address(0)] += amount - 1;
  }

  function supplyWithPermit(bytes32 args, bytes32, bytes32) external {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // For testing, just call the standard supply function
    this.supply(address(0), amount, msg.sender, 0);
  }

  function withdraw(bytes32 args) external returns (uint256) {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // Broken behavior: update balance but with wrong amount (off by 1 wei)
    userBalances[msg.sender][address(0)] -= amount - 1;
    return amount;
  }

  function borrow(bytes32 args) external {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // Specific bug: when borrowing exactly 333e6, double the amount
    if (amount == 333e6) {
      userDebt[msg.sender] += amount * 2; // Double the debt
    } else {
      userDebt[msg.sender] += amount; // Normal behavior
    }
  }

  function repay(bytes32 args) external returns (uint256) {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    if (!breakRepayDebt) {
      // Normal behavior - decrease debt
      userDebt[msg.sender] -= amount;
    } else {
      // Broken behavior: decrease debt but by wrong amount (off by 1 wei)
      userDebt[msg.sender] -= amount - 1;
    }
    return amount;
  }

  function repayWithPermit(bytes32 args, bytes32, bytes32) external returns (uint256) {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // For testing, just call the standard repay function
    return this.repay(address(0), amount, 2, msg.sender);
  }

  function repayWithATokens(bytes32 args) external returns (uint256) {
    // Decode parameters (simplified)
    uint256 amount = uint256(args >> 16) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    // For testing, just call the standard repay function
    return this.repay(address(0), amount, 2, msg.sender);
  }

  function setUserUseReserveAsCollateral(bytes32 args) external {
    // No-op for testing
  }

  function liquidationCall(bytes32 args1, bytes32 args2) external {
    // Decode L2Pool liquidation parameters:
    // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
    // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
    uint16 collateralAssetId = uint16(uint256(args1));
    uint16 debtAssetId = uint16(uint256(args1) >> 16);
    address user = address(uint160(uint256(args1) >> 32));
    uint256 debtToCover = uint256(uint128(uint256(args2)));

    // Get current user state
    uint256 currentDebt = userDebt[user];
    address collateralAsset = getAssetAddressById(collateralAssetId);
    address debtAsset = getAssetAddressById(debtAssetId);
    uint256 currentCollateral = userBalances[user][collateralAsset];

    // Implement subtle broken behaviors that are harder to detect

    // For deficit creation test: create deficit while user still has collateral
    if (currentDebt > 0 && currentCollateral > 0) {
      // Burn all debt but leave some collateral (violates deficit creation rule)
      userDebt[user] = 0;
      // Don't clear collateral - this should trigger the assertion
    }

    // For deficit accounting test: update reserve deficit but with wrong amount
    if (currentDebt > 0) {
      uint256 debtToBurn = debtToCover > currentDebt ? currentDebt : debtToCover;
      userDebt[user] -= debtToBurn;
      // Update deficit but with wrong amount (off by 1 wei)
      reserveDeficits[debtAsset] += debtToBurn - 1;
    }

    // For deficit amount test: set deficit to wrong amount
    if (currentDebt > 0) {
      reserveDeficits[debtAsset] = currentDebt / 2; // Set deficit to half of debt
    }

    // For active reserve deficit test: create deficit on inactive reserve
    if (currentDebt > 0 && !isActive[debtAsset]) {
      reserveDeficits[debtAsset] = currentDebt;
    }

    // For liquidation amounts test: leave insufficient leftover
    if (currentDebt > 0) {
      uint256 debtToBurn = debtToCover > currentDebt ? currentDebt : debtToCover;
      userDebt[user] -= debtToBurn;
      // Leave very small amount (less than MIN_LEFTOVER_BASE)
      if (userDebt[user] > 0 && userDebt[user] < 100e18) {
        userDebt[user] = 1; // Set to 1 wei (much less than MIN_LEFTOVER_BASE)
      }
    }
  }

  // Helper function to map asset IDs to addresses for testing
  function getAssetAddressById(uint16 assetId) internal pure returns (address) {
    // For testing purposes, we'll use a simple mapping
    // In a real implementation, this would query the actual pool
    if (assetId == 1) return address(0x1); // collateral asset
    if (assetId == 2) return address(0x2); // debt asset
    return address(0);
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

  function setReserveInterestRateStrategyAddress(
    address asset,
    address rateStrategyAddress
  ) external {}

  function setConfiguration(
    address asset,
    DataTypes.ReserveConfigurationMap calldata configuration
  ) external {}

  function getConfiguration(
    address
  ) external pure returns (DataTypes.ReserveConfigurationMap memory) {
    return DataTypes.ReserveConfigurationMap(0);
  }

  function getUserConfiguration(
    address
  ) external pure returns (DataTypes.UserConfigurationMap memory) {
    return DataTypes.UserConfigurationMap(0);
  }

  function getReserveNormalizedIncome(address) external pure returns (uint256) {
    return 1e27;
  }

  function getReserveNormalizedVariableDebt(address) external pure returns (uint256) {
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

  function getReserveAddressById(uint16 assetId) external pure returns (address) {
    // For testing purposes, we'll use a simple mapping
    // In a real implementation, this would query the actual pool
    if (assetId == 1) return address(0x1); // collateral asset
    if (assetId == 2) return address(0x2); // debt asset
    return address(0);
  }

  function getAddressesProvider() external pure returns (address) {
    return address(0);
  }

  function setPause(bool val) external {}

  function getPaused() external pure returns (bool) {
    return false;
  }

  function getCloseFactor() external pure returns (uint256) {
    return 5000; // 50%
  }

  function MIN_BASE_MAX_CLOSE_FACTOR_THRESHOLD() external pure returns (uint256) {
    return 1000e18;
  }

  function MIN_LEFTOVER_BASE() external pure returns (uint256) {
    return 100e18;
  }

  function getUserCollateralBalance(address user, address asset) external view returns (uint256) {
    return userBalances[user][asset];
  }

  function getUserDebtBalance(address user, address) external view returns (uint256) {
    return userDebt[user];
  }

  function getReserveDeficit(address asset) external view returns (uint256) {
    return reserveDeficits[asset];
  }

  function getLiquidationGracePeriod(address asset) external view returns (uint40) {
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
    uint256[] calldata,
    address,
    bytes calldata,
    uint16
  ) external {
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
    bytes calldata,
    uint16
  ) external {
    if (breakFlashloanRepayment) {
      // Broken behavior: Transfer tokens but don't require repayment
      IERC20(asset).transfer(receiverAddress, amount);
    }
    // Not broken behavior: Do nothing, pretending no state has changed
  }
}
