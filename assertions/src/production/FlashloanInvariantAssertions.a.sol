// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockL2Pool} from '../interfaces/IMockL2Pool.sol';
import {DataTypes} from '../../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {ReserveConfiguration} from '../../../src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {IERC20} from '../../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

/// @title FlashloanInvariantAssertions
/// @notice Implements the flashloan invariants defined in FlashloanPostconditionsSpec.t.sol
/// @dev Each assertion function implements one or more invariants from FlashloanPostconditionsSpec
contract FlashloanInvariantAssertions is Assertion {
  function triggers() public view override {
    // Register triggers for flashloan functions
    registerCallTrigger(this.assertFlashloanReserveState.selector, IMockL2Pool.flashLoan.selector);
    registerCallTrigger(
      this.assertFlashloanBalanceChanges.selector,
      IMockL2Pool.flashLoan.selector
    );
    registerCallTrigger(this.assertFlashloanFeePayment.selector, IMockL2Pool.flashLoan.selector);
  }

  ////////////////////////////////////////////////////////////////////////////////////////////////////
  //                                    CORE INVARIANT IMPLEMENTATIONS                               //
  ////////////////////////////////////////////////////////////////////////////////////////////////////

  // FLASHLOAN_HSPOST_A: Flashloan can only be performed when the reserve is active and not paused
  function assertFlashloanReserveState() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.flashLoan.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode L2Pool flashLoan parameters: assetId (16 bits) + amount (128 bits) + referralCode (16 bits)
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      uint16 assetId = uint16(uint256(args));

      // Get the asset address from the assetId
      address asset = pool.getReserveAddressById(assetId);
      if (asset == address(0)) continue; // Skip if asset not found

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Check reserve is active
      require(ReserveConfiguration.getActive(reserveData.configuration), 'Reserve is not active');

      // Check reserve is not paused
      require(!ReserveConfiguration.getPaused(reserveData.configuration), 'Reserve is paused');
    }
  }

  // FLASHLOAN_HSPOST_B: Flashloan must return the borrowed amount plus fees
  function assertFlashloanBalanceChanges() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.flashLoan.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode L2Pool flashLoan parameters: assetId (16 bits) + amount (128 bits) + referralCode (16 bits)
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      uint16 assetId = uint16(uint256(args));

      // Get the asset address from the assetId
      address asset = pool.getReserveAddressById(assetId);
      if (asset == address(0)) continue; // Skip if asset not found

      // Get pool balance before flashloan
      ph.forkPreState();
      uint256 poolBalanceBefore = IERC20(asset).balanceOf(address(pool));

      // Get pool balance after flashloan
      ph.forkPostState();
      uint256 poolBalanceAfter = IERC20(asset).balanceOf(address(pool));

      // Pool balance should be at least the original amount (flashloan should be repaid)
      require(poolBalanceAfter >= poolBalanceBefore, 'Flashloan not repaid');
    }
  }

  // FLASHLOAN_HSPOST_C: Flashloan fees must be paid correctly
  function assertFlashloanFeePayment() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.flashLoan.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode L2Pool flashLoan parameters: assetId (16 bits) + amount (128 bits) + referralCode (16 bits)
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      uint16 assetId = uint16(uint256(args));
      uint256 amount = uint256(uint128(uint256(args) >> 16));

      // Get the asset address from the assetId
      address asset = pool.getReserveAddressById(assetId);
      if (asset == address(0)) continue; // Skip if asset not found

      // Calculate expected fee (0.05% is standard for Aave V3)
      uint256 expectedFee = (amount * 5) / 10000;

      // Get pool balance before flashloan
      ph.forkPreState();
      uint256 poolBalanceBefore = IERC20(asset).balanceOf(address(pool));

      // Get pool balance after flashloan
      ph.forkPostState();
      uint256 poolBalanceAfter = IERC20(asset).balanceOf(address(pool));

      // Pool should receive at least the expected fee
      uint256 actualFee = poolBalanceAfter - poolBalanceBefore;
      require(actualFee >= expectedFee, 'Flashloan fee not paid correctly');
    }
  }
}
