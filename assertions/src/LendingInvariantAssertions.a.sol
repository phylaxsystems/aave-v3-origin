// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockL2Pool} from './IMockL2Pool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {ReserveConfiguration} from '../../src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {ReserveConfiguration} from '../../src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';

/// @title LendingInvariantAssertions
/// @notice Implements the lending invariants defined in LendingPostconditionsSpec.t.sol
/// @dev Each assertion function implements one or more invariants from LendingPostconditionsSpec
contract LendingInvariantAssertions is Assertion {
  function triggers() public view override {
    // Register triggers for core lending functions
    registerCallTrigger(this.assertDepositConditions.selector, IMockL2Pool.supply.selector);
    registerCallTrigger(this.assertWithdrawConditions.selector, IMockL2Pool.withdraw.selector);
    registerCallTrigger(this.assertTotalSupplyCap.selector, IMockL2Pool.supply.selector);
    registerCallTrigger(
      this.assertDepositBalanceChangesWithoutHelper.selector,
      IMockL2Pool.supply.selector
    );
    registerCallTrigger(this.assertWithdrawBalanceChanges.selector, IMockL2Pool.withdraw.selector);
    registerCallTrigger(
      this.assertCollateralWithdrawHealth.selector,
      IMockL2Pool.withdraw.selector
    );
  }

  ////////////////////////////////////////////////////////////////////////////////////////////////////
  //                                    CORE INVARIANT IMPLEMENTATIONS                               //
  ////////////////////////////////////////////////////////////////////////////////////////////////////

  /// @notice Implements LENDING_GPOST_A: Reserve must be active, not frozen, and not paused for deposits
  function assertDepositConditions() external {
    IMockL2Pool pool = IMockL2Pool(address(ph.getAssertionAdopter()));
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.supply.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      (address asset, , ) = _decodeSupplyParams(callInputs[i].input);

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Check reserve is active
      require(ReserveConfiguration.getActive(reserveData.configuration), 'Reserve is not active');

      // Check reserve is not frozen
      require(!ReserveConfiguration.getFrozen(reserveData.configuration), 'Reserve is frozen');

      // Check reserve is not paused
      require(!ReserveConfiguration.getPaused(reserveData.configuration), 'Reserve is paused');
    }
  }

  /// @notice Implements LENDING_GPOST_B: Reserve must be active, not frozen, and not paused for withdrawals
  function assertWithdrawConditions() external view {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.withdraw.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      (address asset, ) = _decodeWithdrawParams(callInputs[i].input);

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Check reserve is active
      require(ReserveConfiguration.getActive(reserveData.configuration), 'Reserve is not active');

      // Check reserve is not frozen
      require(!ReserveConfiguration.getFrozen(reserveData.configuration), 'Reserve is frozen');

      // Check reserve is not paused
      require(!ReserveConfiguration.getPaused(reserveData.configuration), 'Reserve is paused');
    }
  }

  /// @notice Implements LENDING_GPOST_C: Total supply must not exceed supply cap
  function assertTotalSupplyCap() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.supply.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      (address asset, uint256 amount, ) = _decodeSupplyParams(callInputs[i].input);

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Check supply cap
      uint256 supplyCap = ReserveConfiguration.getSupplyCap(reserveData.configuration);
      if (supplyCap != 0) {
        // Get current aToken supply
        address aTokenAddress = reserveData.aTokenAddress;
        uint256 currentATokenSupply = IERC20(aTokenAddress).totalSupply();
        require(currentATokenSupply + amount <= supplyCap, 'Supply cap exceeded');
      }
    }
  }

  /// @notice Implements LENDING_GPOST_D: User balance must decrease by deposit amount
  function assertDepositBalanceChangesWithoutHelper() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.supply.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      (address asset, uint256 amount, ) = _decodeSupplyParams(callInputs[i].input);
      address onBehalfOf = callInputs[i].caller;

      // Get aToken address
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);
      address aTokenAddress = reserveData.aTokenAddress;

      // Get balances before
      ph.forkPreState();
      uint256 userBalanceBefore = _getUserBalance(asset, onBehalfOf);
      uint256 aTokenBalanceBefore = _getATokenBalance(aTokenAddress, onBehalfOf);

      // Get balances after
      ph.forkPostState();
      uint256 userBalanceAfter = _getUserBalance(asset, onBehalfOf);
      uint256 aTokenBalanceAfter = _getATokenBalance(aTokenAddress, onBehalfOf);

      // Check user balance decreased by deposit amount
      require(
        userBalanceBefore - userBalanceAfter >= amount,
        'User balance did not decrease by deposit amount'
      );

      // Check aToken balance increased by deposit amount
      require(
        aTokenBalanceAfter - aTokenBalanceBefore >= amount,
        'aToken balance did not increase by deposit amount'
      );
    }
  }

  /// @notice Implements LENDING_GPOST_E: User balance must increase by withdraw amount
  function assertWithdrawBalanceChanges() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.withdraw.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      (address asset, uint256 amount) = _decodeWithdrawParams(callInputs[i].input);
      address to = callInputs[i].caller;

      // Get aToken address
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);
      address aTokenAddress = reserveData.aTokenAddress;

      // Get balances before
      ph.forkPreState();
      uint256 userBalanceBefore = _getUserBalance(asset, to);
      uint256 aTokenBalanceBefore = _getATokenBalance(aTokenAddress, to);

      // Get balances after
      ph.forkPostState();
      uint256 userBalanceAfter = _getUserBalance(asset, to);
      uint256 aTokenBalanceAfter = _getATokenBalance(aTokenAddress, to);

      // Check user balance increased by withdraw amount
      require(
        userBalanceAfter - userBalanceBefore >= amount,
        'User balance did not increase by withdraw amount'
      );

      // Check aToken balance decreased by withdraw amount
      require(
        aTokenBalanceBefore - aTokenBalanceAfter >= amount,
        'aToken balance did not decrease by withdraw amount'
      );
    }
  }

  /// @notice Implements LENDING_GPOST_F: Withdrawing collateral must maintain health factor
  function assertCollateralWithdrawHealth() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.withdraw.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      address user = callInputs[i].caller;

      // Get health factor before
      ph.forkPreState();
      uint256 preHealthFactor;
      (, , , , , preHealthFactor) = pool.getUserAccountData(user);

      // Get health factor after
      ph.forkPostState();
      uint256 postHealthFactor;
      (, , , , , postHealthFactor) = pool.getUserAccountData(user);

      // Health factor should not decrease significantly when withdrawing collateral
      // Allow for small precision differences
      require(
        postHealthFactor >= preHealthFactor - 1e16, // Allow 1% tolerance
        'Health factor decreased too much after collateral withdrawal'
      );
    }
  }

  ////////////////////////////////////////////////////////////////////////////////////////////////////
  //                                    HELPER FUNCTIONS                                            //
  ////////////////////////////////////////////////////////////////////////////////////////////////////

  /// @notice Decodes L2Pool supply parameters using CalldataLogic approach
  /// @param input The encoded input data
  /// @return asset The asset address
  /// @return amount The amount to supply
  /// @return referralCode The referral code
  function _decodeSupplyParams(
    bytes memory input
  ) internal view returns (address asset, uint256 amount, uint16 referralCode) {
    bytes32 args = abi.decode(input, (bytes32));

    uint16 assetId;
    assembly {
      assetId := and(args, 0xFFFF)
      amount := and(shr(16, args), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
      referralCode := and(shr(144, args), 0xFFFF)
    }

    // Get asset address from asset ID using pool's getReserveData
    // We need to iterate through reserves to find the one with matching ID
    // This is a simplified approach - in practice you might want to maintain a mapping
    asset = _getAssetAddressById(assetId);
  }

  /// @notice Decodes L2Pool withdraw parameters using CalldataLogic approach
  /// @param input The encoded input data
  /// @return asset The asset address
  /// @return amount The amount to withdraw
  function _decodeWithdrawParams(
    bytes memory input
  ) internal view returns (address asset, uint256 amount) {
    bytes32 args = abi.decode(input, (bytes32));

    uint16 assetId;
    assembly {
      assetId := and(args, 0xFFFF)
      amount := and(shr(16, args), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
    }

    if (amount == type(uint128).max) {
      amount = type(uint256).max;
    }

    // Get asset address from asset ID
    asset = _getAssetAddressById(assetId);
  }

  /// @notice Helper function to get asset address from asset ID
  /// @param assetId The asset ID
  /// @return The asset address
  function _getAssetAddressById(uint16 assetId) internal view returns (address) {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    return pool.getReserveAddressById(assetId);
  }

  /// @notice Helper function to get user's underlying token balance
  /// @param asset The asset address
  /// @param user The user address
  /// @return The user's balance
  function _getUserBalance(address asset, address user) internal view returns (uint256) {
    return IERC20(asset).balanceOf(user);
  }

  /// @notice Helper function to get user's aToken balance
  /// @param aTokenAddress The aToken address
  /// @param user The user address
  /// @return The user's aToken balance
  function _getATokenBalance(address aTokenAddress, address user) internal view returns (uint256) {
    return IERC20(aTokenAddress).balanceOf(user);
  }
}
