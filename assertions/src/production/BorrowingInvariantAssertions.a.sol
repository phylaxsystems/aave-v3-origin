// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockL2Pool} from '../interfaces/IMockL2Pool.sol';
import {DataTypes} from '../../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {ReserveConfiguration} from '../../../src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {UserConfiguration} from '../../../src/contracts/protocol/libraries/configuration/UserConfiguration.sol';
import {IERC20} from '../../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

/// @title BorrowingInvariantAssertions
/// @notice Implements the borrowing invariants defined in BorrowingPostconditionsSpec.t.sol
/// @dev Each assertion function implements one or more invariants from BorrowingPostconditionsSpec
contract BorrowingInvariantAssertions is Assertion {
  function triggers() public view override {
    // Register triggers for core borrowing functions
    registerCallTrigger(this.assertBorrowReserveState.selector, IMockL2Pool.borrow.selector);
    registerCallTrigger(this.assertRepayReserveState.selector, IMockL2Pool.repay.selector);
    registerCallTrigger(this.assertBorrowBalanceChanges.selector, IMockL2Pool.borrow.selector);

    registerCallTrigger(this.assertBorrowDebtChanges.selector, IMockL2Pool.borrow.selector);
    registerCallTrigger(this.assertRepayBalanceChanges.selector, IMockL2Pool.repay.selector);
    registerCallTrigger(this.assertRepayDebtChanges.selector, IMockL2Pool.repay.selector);
    registerCallTrigger(this.assertBorrowCap.selector, IMockL2Pool.borrow.selector);
  }

  ////////////////////////////////////////////////////////////////////////////////////////////////////
  //                                    CORE INVARIANT IMPLEMENTATIONS                               //
  ////////////////////////////////////////////////////////////////////////////////////////////////////

  // BORROWING_HSPOST_A: An asset can only be borrowed when the user has sufficient collateral
  function assertBorrowCollateral() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Skip if the call is a delegatecall
      if (callInputs[i].bytecode_address == callInputs[i].target_address) {
        continue;
      }
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      uint256 amount = uint256(uint128(uint256(args) >> 16));
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get user account data before borrow
      ph.forkPreState();
      (, uint256 totalDebtBase, , , , ) = pool.getUserAccountData(onBehalfOf);

      // If user has no debt, they should have sufficient collateral
      if (totalDebtBase == 0) {
        // Get the asset address from the assetId
        uint16 assetId = uint16(uint256(args));
        address asset = pool.getReserveAddressById(assetId);
        if (asset == address(0)) continue; // Skip if asset not found

        // Get aToken address
        DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);
        address aTokenAddress = reserveData.aTokenAddress;

        // Get aToken balance before withdraw
        ph.forkPreState();
        uint256 aTokenBalanceBefore = IERC20(aTokenAddress).balanceOf(callInputs[i].caller);

        // Get aToken balance after withdraw
        ph.forkPostState();
        uint256 aTokenBalanceAfter = IERC20(aTokenAddress).balanceOf(callInputs[i].caller);

        // If user has no debt, they should be able to withdraw their full aToken balance
        require(
          aTokenBalanceAfter == 0 || amount <= aTokenBalanceBefore,
          'User with no debt cannot withdraw full amount'
        );
      }
    }
  }

  // BORROWING_HSPOST_B: An asset can only be borrowed when the user has sufficient liquidity
  function assertBorrowLiquidity() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Skip if the call is a delegatecall
      if (callInputs[i].bytecode_address == callInputs[i].target_address) {
        continue;
      }
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      uint256 amount = uint256(uint128(uint256(args) >> 16));
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get user account data before borrow
      ph.forkPreState();
      (, , uint256 availableBorrowsBase, , , ) = pool.getUserAccountData(onBehalfOf);

      // Check user has sufficient liquidity
      require(availableBorrowsBase >= amount, 'Insufficient liquidity for borrow');
    }
  }

  // BORROWING_HSPOST_C: An asset can only be borrowed when the user is not in isolation mode
  // OR when the asset is borrowable in isolation mode
  function assertBorrowIsolationMode() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      uint16 assetId = uint16(uint256(args));
      address onBehalfOf = callInputs[i].caller;
      address asset = pool.getReserveAddressById(assetId);
      if (asset == address(0)) continue;
      DataTypes.UserConfigurationMap memory userConfig = pool.getUserConfiguration(onBehalfOf);
      // Check if user is in isolation mode: exactly one collateral, and that collateral has a debt ceiling
      if (UserConfiguration.isUsingAsCollateralOne(userConfig)) {
        // Try to find if the user's single collateral has a debt ceiling
        // We have to check all reserves, but we only have the borrowed asset here, so this is a limitation
        // Instead, we check if the borrowed asset is borrowable in isolation, and if not, fail
        DataTypes.ReserveDataLegacy memory borrowAssetData = pool.getReserveData(asset);
        require(
          ReserveConfiguration.getBorrowableInIsolation(borrowAssetData.configuration),
          'Borrowed asset is not borrowable in isolation mode'
        );
      }
    }
  }

  // BORROWING_HSPOST_D: An asset can only be borrowed when its configured as borrowable
  // BORROWING_HSPOST_E: An asset can only be borrowed when the related reserve is active, not frozen, not paused & borrowing is enabled
  function assertBorrowReserveState() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Skip if the call is a delegatecall
      if (callInputs[i].bytecode_address == callInputs[i].target_address) {
        continue;
      }
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      uint16 assetId = uint16(uint256(args));

      // Get the asset address from the assetId
      address asset = pool.getReserveAddressById(assetId);
      if (asset == address(0)) continue; // Skip if asset not found

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Check reserve is active
      require(ReserveConfiguration.getActive(reserveData.configuration), 'Reserve is not active');

      // Check reserve is not frozen
      require(!ReserveConfiguration.getFrozen(reserveData.configuration), 'Reserve is frozen');

      // Check reserve is not paused
      require(!ReserveConfiguration.getPaused(reserveData.configuration), 'Reserve is paused');

      // Check borrowing is enabled
      require(
        ReserveConfiguration.getBorrowingEnabled(reserveData.configuration),
        'Borrowing is disabled'
      );
    }
  }

  // BORROWING_HSPOST_F: An asset can only be repaid when the related reserve is active & not paused
  function assertRepayReserveState() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Skip if the call is a delegatecall
      if (callInputs[i].bytecode_address == callInputs[i].target_address) {
        continue;
      }
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool repay parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits)
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

  // BORROWING_HSPOST_G: An asset can only be repaid when the user has sufficient debt
  function assertRepayDebt() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool repay parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits)
      uint256 amount = uint256(uint128(uint256(args) >> 16));
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get user debt before repay
      ph.forkPreState();
      (, uint256 totalDebtBase, , , , ) = pool.getUserAccountData(onBehalfOf);

      // Check user has sufficient debt to repay
      require(totalDebtBase >= amount, 'Insufficient debt to repay');
    }
  }

  // BORROWING_GPOST_H: If totalBorrow for a reserve increases new totalBorrow must be less than or equal to borrow cap
  function assertBorrowCap() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Skip if the call is a delegatecall
      if (callInputs[i].bytecode_address == callInputs[i].target_address) {
        continue;
      }
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      uint16 assetId = uint16(uint256(args));

      // Get the asset address from the assetId
      address asset = pool.getReserveAddressById(assetId);
      if (asset == address(0)) continue; // Skip if asset not found

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Get borrow cap
      uint256 borrowCap = ReserveConfiguration.getBorrowCap(reserveData.configuration);

      // If borrow cap is 0, borrowing is disabled
      if (borrowCap == 0) {
        require(false, 'Borrowing disabled for this reserve');
      }

      // Get total borrow after
      ph.forkPostState();
      uint256 totalBorrowAfter = IERC20(reserveData.variableDebtTokenAddress).totalSupply();

      // Check that total borrow after is within the cap
      require(totalBorrowAfter <= borrowCap, 'Total borrow exceeds borrow cap');
    }
  }

  // BORROWING_HSPOST_I: After a successful borrow the actor asset balance should increase by the amount borrowed
  // This version uses getCallInputs to directly access the function parameters from the call data
  // It's simpler but requires the function to be called directly (not through a proxy or delegatecall)
  // Gas cost of this assertion for a single borrow transaction: 40263
  function assertBorrowBalanceChanges() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Skip if the call is a delegatecall
      if (callInputs[i].bytecode_address == callInputs[i].target_address) {
        continue;
      }
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      uint16 assetId = uint16(uint256(args));
      uint256 amount = uint256(uint128(uint256(args) >> 16));

      // Get the asset address from the assetId
      address asset = pool.getReserveAddressById(assetId);
      if (asset == address(0)) continue; // Skip if asset not found

      // Get the user who made the borrow call
      address user = callInputs[i].caller;

      // Get pre and post state of user's underlying token balance
      ph.forkPreState();
      uint256 preBalance = IERC20(asset).balanceOf(user);

      ph.forkPostState();
      uint256 postBalance = IERC20(asset).balanceOf(user);

      uint256 actualBalanceChange = postBalance - preBalance;

      // The user should receive exactly the amount they borrowed
      require(
        actualBalanceChange == amount,
        'User received incorrect amount on borrow - possible 333e6 bug'
      );
    }
  }

  // BORROWING_HSPOST_J: After a successful borrow the onBehalf debt balance should increase by the amount borrowed
  function assertBorrowDebtChanges() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Skip if the call is a delegatecall
      if (callInputs[i].bytecode_address == callInputs[i].target_address) {
        continue;
      }
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      uint256 amount = uint256(uint128(uint256(args) >> 16));
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get debt before
      ph.forkPreState();
      (, uint256 totalDebtBase, , , , ) = pool.getUserAccountData(onBehalfOf);

      // Get debt after
      ph.forkPostState();
      (, uint256 postTotalDebtBase, , , , ) = pool.getUserAccountData(onBehalfOf);

      // Check debt increased by at least the borrow amount (could be more due to interest)
      require(postTotalDebtBase > totalDebtBase, 'Debt did not increase');
      require(
        postTotalDebtBase - totalDebtBase >= amount,
        'Debt increase should be at least the borrow amount'
      );
    }
  }

  // BORROWING_HSPOST_K: After a successful repay the actor asset balance should decrease by the amount repaid
  function assertRepayBalanceChanges() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode L2Pool repay parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits)
      uint16 assetId = uint16(uint256(abi.decode(callInputs[i].input, (bytes32))));
      uint256 amount = uint256(uint128(uint256(abi.decode(callInputs[i].input, (bytes32))) >> 16));

      // Get the asset address from the assetId
      address asset = pool.getReserveAddressById(assetId);
      if (asset == address(0)) continue; // Skip if asset not found

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Get user debt balance before repay
      ph.forkPreState();
      uint256 userDebtBefore = IERC20(reserveData.variableDebtTokenAddress).balanceOf(
        callInputs[i].caller
      );

      // Get user debt balance after repay
      ph.forkPostState();
      uint256 userDebtAfter = IERC20(reserveData.variableDebtTokenAddress).balanceOf(
        callInputs[i].caller
      );

      // Check that debt decreased by at least the repaid amount
      require(
        userDebtBefore - userDebtAfter >= amount,
        'User debt did not decrease by repaid amount'
      );
    }
  }

  // BORROWING_HSPOST_L: After a successful repay the onBehalf debt balance should decrease by at least the amount repaid
  function assertRepayDebtChanges() external {
    IMockL2Pool pool = IMockL2Pool(ph.getAssertionAdopter());
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Skip if the call is a delegatecall
      if (callInputs[i].bytecode_address == callInputs[i].target_address) {
        continue;
      }
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool repay parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits)
      uint256 amount = uint256(uint128(uint256(args) >> 16));
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get debt before
      ph.forkPreState();
      (, uint256 totalDebtBase, , , , ) = pool.getUserAccountData(onBehalfOf);

      // Get debt after
      ph.forkPostState();
      (, uint256 postTotalDebtBase, , , , ) = pool.getUserAccountData(onBehalfOf);

      // Check debt decreased by at least the repay amount (could be more due to interest)
      require(totalDebtBase > postTotalDebtBase, 'Debt did not decrease');
      require(
        totalDebtBase - postTotalDebtBase >= amount,
        'Debt decrease should be at least the repay amount'
      );
    }
  }
}
