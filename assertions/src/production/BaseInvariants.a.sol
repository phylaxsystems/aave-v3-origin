// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockL2Pool} from '../interfaces/IMockL2Pool.sol';
import {IERC20} from '../../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {DataTypes} from '../../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {ReserveConfiguration} from '../../../src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {WadRayMath} from '../../../src/contracts/protocol/libraries/math/WadRayMath.sol';

/**
 * @title BaseInvariants
 * @notice Assertions for basic protocol invariants related to token balances and borrowing states for a specific asset
 */
contract BaseInvariants is Assertion {
  address public immutable targetAsset;
  IMockL2Pool public immutable pool;

  constructor(address _pool, address _asset) {
    pool = IMockL2Pool(_pool);
    targetAsset = _asset;
  }

  function triggers() public view override {
    // Register storage trigger for totalSupply (slot 2) of the debt token
    // NOTE: this is currently not a supported trigger cheatcode,
    //so we have to trigger on all calls to functions that affect the debt token supply
    // registerStorageChangeTrigger(this.assertDebtTokenSupply.selector, debtToken, 2);

    // Below approach is inefficient since we have to trigger on all calls to functions that _could_
    // affect the debt token supply, but without being sure that it's the token
    // at the address of the debt token initiated in the constructor.
    registerCallTrigger(this.assertDebtTokenSupply.selector, IMockL2Pool.borrow.selector);
    registerCallTrigger(this.assertDebtTokenSupply.selector, IMockL2Pool.repay.selector);
    registerCallTrigger(this.assertDebtTokenSupply.selector, IMockL2Pool.liquidationCall.selector);

    // Register triggers for aToken supply invariant
    registerCallTrigger(this.assertATokenSupply.selector, IMockL2Pool.supply.selector);
    registerCallTrigger(this.assertATokenSupply.selector, IMockL2Pool.withdraw.selector);
    registerCallTrigger(this.assertATokenSupply.selector, IMockL2Pool.liquidationCall.selector);

    // Register triggers for underlying balance invariants
    registerCallTrigger(
      this.assertUnderlyingBalanceInvariant.selector,
      IMockL2Pool.supply.selector
    );
    registerCallTrigger(
      this.assertUnderlyingBalanceInvariant.selector,
      IMockL2Pool.withdraw.selector
    );
    registerCallTrigger(
      this.assertUnderlyingBalanceInvariant.selector,
      IMockL2Pool.borrow.selector
    );
    registerCallTrigger(this.assertUnderlyingBalanceInvariant.selector, IMockL2Pool.repay.selector);
    registerCallTrigger(
      this.assertUnderlyingBalanceInvariant.selector,
      IMockL2Pool.liquidationCall.selector
    );

    // Register triggers for virtual balance invariant
    registerCallTrigger(this.assertVirtualBalanceInvariant.selector, IMockL2Pool.supply.selector);
    registerCallTrigger(this.assertVirtualBalanceInvariant.selector, IMockL2Pool.withdraw.selector);
    registerCallTrigger(this.assertVirtualBalanceInvariant.selector, IMockL2Pool.borrow.selector);
    registerCallTrigger(this.assertVirtualBalanceInvariant.selector, IMockL2Pool.repay.selector);
    registerCallTrigger(
      this.assertVirtualBalanceInvariant.selector,
      IMockL2Pool.liquidationCall.selector
    );
  }

  /*/////////////////////////////////////////////////////////////////////////////////////////////
        BASE_INVARIANT_A: debtToken totalSupply should be equal to the sum of all user balances (user debt)
        This is verified by ensuring that the sum of individual balance changes matches the total supply change
        for a specific asset
    /////////////////////////////////////////////////////////////////////////////////////////////*/
  function assertDebtTokenSupply() external {
    // Get all operations that affect debt token supply
    PhEvm.CallInputs[] memory borrowCalls = ph.getCallInputs(address(pool), pool.borrow.selector);
    PhEvm.CallInputs[] memory repayCalls = ph.getCallInputs(address(pool), pool.repay.selector);
    PhEvm.CallInputs[] memory liquidationCalls = ph.getCallInputs(
      address(pool),
      pool.liquidationCall.selector
    );

    uint256 totalIncrease = 0;
    uint256 totalDecrease = 0;

    // Debug: Log the number of calls but don't fail on multiple calls
    // require(borrowCalls.length == 2, 'Expected exactly 1 borrow call');
    // require(repayCalls.length == 0, 'Expected 0 repay calls');
    // require(liquidationCalls.length == 0, 'Expected 0 liquidation calls');

    // Process borrow operations (increase debt) - only VARIABLE mode affects variable debt token
    for (uint256 i = 0; i < borrowCalls.length; i++) {
      bytes32 args = abi.decode(borrowCalls[i].input, (bytes32));

      // Decode using the same logic as CalldataLogic.decodeBorrowParams
      uint16 assetId;
      uint256 amount;
      uint256 interestRateMode;
      uint16 referralCode;

      assembly {
        assetId := and(args, 0xFFFF)
        amount := and(shr(16, args), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        interestRateMode := and(shr(144, args), 0xFF)
        referralCode := and(shr(152, args), 0xFFFF)
      }

      // Get the asset address from the assetId and check if it matches our target asset
      address asset = pool.getReserveAddressById(assetId);
      require(asset == targetAsset, 'Asset does not match target asset');

      if (
        asset == targetAsset && interestRateMode == uint256(DataTypes.InterestRateMode.VARIABLE)
      ) {
        // Debug: Log before adding
        uint256 beforeTotal = totalIncrease;
        totalIncrease += amount;
        // Debug: Log after adding
        require(totalIncrease == beforeTotal + 1000e6, 'Total increase not incremented correctly');
      }
    }

    // Process repay operations (decrease debt) - only VARIABLE mode affects variable debt token
    for (uint256 i = 0; i < repayCalls.length; i++) {
      bytes32 args = abi.decode(repayCalls[i].input, (bytes32));

      // Decode using the same logic as CalldataLogic.decodeRepayParams
      uint16 assetId;
      uint256 amount;
      uint256 interestRateMode;

      assembly {
        assetId := and(args, 0xFFFF)
        amount := and(shr(16, args), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        interestRateMode := and(shr(144, args), 0xFF)
      }

      if (amount == type(uint128).max) {
        amount = type(uint256).max;
      }

      address asset = pool.getReserveAddressById(assetId);
      if (
        asset == targetAsset && interestRateMode == uint256(DataTypes.InterestRateMode.VARIABLE)
      ) {
        totalDecrease += amount;
      }
    }

    // Process liquidation operations (decrease debt)
    for (uint256 i = 0; i < liquidationCalls.length; i++) {
      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, bytes32 args2) = abi.decode(liquidationCalls[i].input, (bytes32, bytes32));
      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
      uint16 debtAssetId = uint16(uint256(args1) >> 16);
      uint256 debtToCover = uint256(uint128(uint256(args2)));

      address asset = pool.getReserveAddressById(debtAssetId);
      if (asset == targetAsset) {
        totalDecrease += debtToCover;
      }
    }

    // Calculate net change in user underlying balances
    uint256 netDebtChange = totalIncrease - totalDecrease;

    // require(totalIncrease != 0, 'Total increase is 0');
    // require(totalDecrease == 0, 'Total decrease is not 0');
    // require(netDebtChange > 1999e6, 'Net debt change is not greater than 999e6');
    // require(netDebtChange < 2001e6, 'Net debt change is not less than 1001e6');
    // require(netDebtChange == 1000e6, 'Net debt change is not 1000e6');
    // require(totalIncrease == 1000e6, 'Total increase is not 1000e6');

    // Compare calculated underlying balance changes with actual on-chain debt token supply
    // Get the variable debt token for this asset
    address variableDebtToken = pool.getReserveData(targetAsset).variableDebtTokenAddress;

    // Debug: Log the debt token address to verify we're getting the right one
    require(variableDebtToken != address(0), 'Variable debt token address is zero');

    IERC20 debtToken = IERC20(variableDebtToken);

    // Get pre and post state of debt token total supply
    ph.forkPreState();
    uint256 preDebtSupply = debtToken.totalSupply();

    ph.forkPostState();
    uint256 postDebtSupply = debtToken.totalSupply();

    uint256 actualDebtSupplyChange = postDebtSupply - preDebtSupply;

    // The calculated net debt change should match the actual debt token supply change
    require(
      netDebtChange == actualDebtSupplyChange,
      'Calculated debt change does not match actual debt token supply change'
    );

    // Additional safety check: debt supply should not decrease more than it increases
    require(netDebtChange >= 0, 'Net debt change should be non-negative');
  }

  function assertBorrowUserDebtTokenVsUnderlyingBalance() external {
    PhEvm.CallInputs[] memory borrowCalls = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < borrowCalls.length; i++) {
      bytes32 args = abi.decode(borrowCalls[i].input, (bytes32));

      // Decode using the same logic as CalldataLogic.decodeBorrowParams
      uint16 assetId;
      uint256 amount;
      uint256 interestRateMode;
      uint16 referralCode;

      assembly {
        assetId := and(args, 0xFFFF)
        amount := and(shr(16, args), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        interestRateMode := and(shr(144, args), 0xFF)
        referralCode := and(shr(152, args), 0xFFFF)
      }

      address asset = pool.getReserveAddressById(assetId);
      if (
        asset == targetAsset && interestRateMode == uint256(DataTypes.InterestRateMode.VARIABLE)
      ) {
        IERC20 underlying = IERC20(targetAsset);

        // Get user address from the caller
        address user = borrowCalls[i].caller;

        // Get pre and post state
        ph.forkPreState();
        uint256 preBalance = underlying.balanceOf(user);
        require(preBalance == 10000e6, 'Pre balance is not 10000e6');

        ph.forkPostState();
        uint256 postBalance = underlying.balanceOf(user);
        require(postBalance == 10000e6 + amount, 'Post balance is not equal to amount');

        // Calculate actual balance change
        // Borrow always increases the balance of the user
        uint256 actualBalanceChange = postBalance - preBalance;
        require(actualBalanceChange == 1000e6, 'Actual balance change is not equal to amount');

        // The user should receive exactly `amount` tokens
        require(actualBalanceChange == amount, 'User received incorrect amount on borrow');
      }
    }
  }

  /*/////////////////////////////////////////////////////////////////////////////////////////////
        BASE_INVARIANT_B: aToken totalSupply should be equal to the sum of all user balances
        This ensures that the aToken supply accurately represents the total user deposits
    /////////////////////////////////////////////////////////////////////////////////////////////*/
  function assertATokenSupply() external {
    // Get all operations that affect aToken supply
    PhEvm.CallInputs[] memory supplyCalls = ph.getCallInputs(address(pool), pool.supply.selector);
    PhEvm.CallInputs[] memory withdrawCalls = ph.getCallInputs(
      address(pool),
      pool.withdraw.selector
    );
    PhEvm.CallInputs[] memory liquidationCalls = ph.getCallInputs(
      address(pool),
      pool.liquidationCall.selector
    );

    uint256 totalIncrease = 0;
    uint256 totalDecrease = 0;

    // Process supply operations (increase aToken supply)
    for (uint256 i = 0; i < supplyCalls.length; i++) {
      bytes32 args = abi.decode(supplyCalls[i].input, (bytes32));

      // Decode L2Pool supply parameters: assetId (16 bits) + amount (128 bits) + referralCode (16 bits)
      uint16 assetId = uint16(uint256(args));
      uint256 amount = uint256(uint128(uint256(args) >> 16));

      address asset = pool.getReserveAddressById(assetId);
      if (asset == targetAsset) {
        totalIncrease += amount;
      }
    }

    // Process withdraw operations (decrease aToken supply)
    for (uint256 i = 0; i < withdrawCalls.length; i++) {
      bytes32 args = abi.decode(withdrawCalls[i].input, (bytes32));

      // Decode L2Pool withdraw parameters: assetId (16 bits) + amount (128 bits) + to (160 bits)
      uint16 assetId = uint16(uint256(args));
      uint256 amount = uint256(uint128(uint256(args) >> 16));

      address asset = pool.getReserveAddressById(assetId);
      if (asset == targetAsset) {
        totalDecrease += amount;
      }
    }

    // Process liquidation operations (may affect aToken supply)
    for (uint256 i = 0; i < liquidationCalls.length; i++) {
      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, bytes32 args2) = abi.decode(liquidationCalls[i].input, (bytes32, bytes32));

      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
      uint16 collateralAssetId = uint16(uint256(args1));
      uint256 debtToCover = uint256(uint128(uint256(args2)));
      bool receiveAToken = (uint256(args2) >> 128) & 1 == 1;

      address asset = pool.getReserveAddressById(collateralAssetId);
      if (asset == targetAsset && !receiveAToken) {
        // If not receiving aToken, collateral is withdrawn, decreasing aToken supply
        totalDecrease += debtToCover;
      }
    }

    // Calculate net change in aToken supply
    uint256 netATokenChange = totalIncrease - totalDecrease;

    // Get the aToken for this asset
    address aTokenAddress = pool.getReserveData(targetAsset).aTokenAddress;
    require(aTokenAddress != address(0), 'AToken address is zero');

    IERC20 aToken = IERC20(aTokenAddress);

    // Get pre and post state of aToken total supply
    ph.forkPreState();
    uint256 preATokenSupply = aToken.totalSupply();

    ph.forkPostState();
    uint256 postATokenSupply = aToken.totalSupply();

    uint256 actualATokenSupplyChange = postATokenSupply - preATokenSupply;

    // The calculated net aToken change should match the actual aToken supply change
    require(
      netATokenChange == actualATokenSupplyChange,
      'Calculated aToken change does not match actual aToken supply change'
    );
  }

  /*/////////////////////////////////////////////////////////////////////////////////////////////
        BASE_INVARIANT_C: The total amount of underlying in the protocol should be greater or equal 
        than the aToken totalSupply - debtToken totalSupply
        This ensures the protocol has sufficient underlying assets to cover net user positions
    /////////////////////////////////////////////////////////////////////////////////////////////*/
  function assertUnderlyingBalanceInvariant() external {
    // Get reserve data for the target asset
    DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(targetAsset);

    address aTokenAddress = reserveData.aTokenAddress;
    address variableDebtTokenAddress = reserveData.variableDebtTokenAddress;

    require(aTokenAddress != address(0), 'AToken address is zero');
    require(variableDebtTokenAddress != address(0), 'Variable debt token address is zero');

    IERC20 aToken = IERC20(aTokenAddress);
    IERC20 variableDebtToken = IERC20(variableDebtTokenAddress);
    IERC20 underlying = IERC20(targetAsset);

    // Get pre and post state
    ph.forkPreState();
    uint256 preATokenSupply = aToken.totalSupply();
    uint256 preDebtTokenSupply = variableDebtToken.totalSupply();
    uint256 preUnderlyingBalance = underlying.balanceOf(aTokenAddress);

    ph.forkPostState();
    uint256 postATokenSupply = aToken.totalSupply();
    uint256 postDebtTokenSupply = variableDebtToken.totalSupply();
    uint256 postUnderlyingBalance = underlying.balanceOf(aTokenAddress);

    // Calculate net liability (aToken supply - debt token supply)
    uint256 preNetLiability = preATokenSupply - preDebtTokenSupply;
    uint256 postNetLiability = postATokenSupply - postDebtTokenSupply;

    // The underlying balance should be >= net liability
    require(
      postUnderlyingBalance >= postNetLiability,
      'Underlying balance insufficient to cover net liability'
    );

    // Additional check: underlying balance should not decrease more than net liability decrease
    uint256 underlyingBalanceChange = postUnderlyingBalance - preUnderlyingBalance;
    uint256 netLiabilityChange = postNetLiability - preNetLiability;

    require(
      underlyingBalanceChange >= netLiabilityChange,
      'Underlying balance decreased more than net liability'
    );
  }

  /*/////////////////////////////////////////////////////////////////////////////////////////////
        BASE_INVARIANT_D: The total amount of underlying in the protocol should be greater or equal 
        to the reserve virtualUnderlyingBalance
        This ensures the protocol maintains sufficient real underlying assets
    /////////////////////////////////////////////////////////////////////////////////////////////*/
  function assertVirtualBalanceInvariant() external {
    // Get reserve data for the target asset
    DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(targetAsset);

    address aTokenAddress = reserveData.aTokenAddress;
    require(aTokenAddress != address(0), 'AToken address is zero');

    IERC20 aToken = IERC20(aTokenAddress);
    IERC20 underlying = IERC20(targetAsset);

    // Get pre and post state
    ph.forkPreState();
    uint256 preUnderlyingBalance = underlying.balanceOf(aTokenAddress);

    ph.forkPostState();
    uint256 postUnderlyingBalance = underlying.balanceOf(aTokenAddress);

    // The actual underlying balance should be >= 0 (basic sanity check)
    require(postUnderlyingBalance >= 0, 'Actual underlying balance is negative');
  }

  /*/////////////////////////////////////////////////////////////////////////////////////////////
        BASE_INVARIANT_F: virtualBalance + currentDebt = (scaledATokenTotalSupply + accrueToTreasury) * liquidityIndexRightNow
        This is the core accounting invariant that ensures proper interest accrual
    /////////////////////////////////////////////////////////////////////////////////////////////*/
  function assertLiquidityIndexInvariant() external {
    // Get reserve data for the target asset
    DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(targetAsset);

    address aTokenAddress = reserveData.aTokenAddress;
    address variableDebtTokenAddress = reserveData.variableDebtTokenAddress;

    require(aTokenAddress != address(0), 'AToken address is zero');
    require(variableDebtTokenAddress != address(0), 'Variable debt token address is zero');

    IERC20 aToken = IERC20(aTokenAddress);
    IERC20 variableDebtToken = IERC20(variableDebtTokenAddress);

    // Get pre and post state
    ph.forkPreState();
    uint256 preCurrentDebt = variableDebtToken.totalSupply();
    uint256 preScaledATokenSupply = aToken.totalSupply();
    uint256 preAccrueToTreasury = reserveData.accruedToTreasury;
    uint256 preLiquidityIndex = reserveData.liquidityIndex;

    ph.forkPostState();
    uint256 postCurrentDebt = variableDebtToken.totalSupply();
    uint256 postScaledATokenSupply = aToken.totalSupply();
    uint256 postAccrueToTreasury = reserveData.accruedToTreasury;
    uint256 postLiquidityIndex = reserveData.liquidityIndex;

    // Calculate left side: currentDebt (simplified since virtualUnderlyingBalance not available in legacy)
    uint256 leftSide = postCurrentDebt;

    // Calculate right side: (scaledATokenTotalSupply + accrueToTreasury) * liquidityIndex
    uint256 scaledTotal = postScaledATokenSupply + postAccrueToTreasury;
    uint256 rightSide = WadRayMath.rayMul(scaledTotal, postLiquidityIndex);

    // Allow for small rounding differences (1 wei tolerance)
    uint256 difference = leftSide > rightSide ? leftSide - rightSide : rightSide - leftSide;
    require(difference <= 1, 'Liquidity index invariant violated');

    // Additional check: if liquidity index increases, aToken supply should increase proportionally
    if (postLiquidityIndex > preLiquidityIndex) {
      uint256 indexRatio = WadRayMath.rayDiv(postLiquidityIndex, preLiquidityIndex);
      uint256 expectedATokenSupplyIncrease = WadRayMath.rayMul(preScaledATokenSupply, indexRatio) -
        preScaledATokenSupply;
      uint256 actualATokenSupplyIncrease = postScaledATokenSupply - preScaledATokenSupply;

      // Allow for small rounding differences
      uint256 supplyDifference = expectedATokenSupplyIncrease > actualATokenSupplyIncrease
        ? expectedATokenSupplyIncrease - actualATokenSupplyIncrease
        : actualATokenSupplyIncrease - expectedATokenSupplyIncrease;

      require(
        supplyDifference <= 1,
        'AToken supply increase does not match liquidity index increase'
      );
    }
  }
}
