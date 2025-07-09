// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IAaveOracle} from '../../../src/contracts/interfaces/IAaveOracle.sol';
import {IMockL2Pool} from '../interfaces/IMockL2Pool.sol';

/**
 * @title OracleAssertions
 * @notice Assertions for Aave V3 oracle price checks using L2Pool interface
 */
contract OracleAssertions is Assertion {
  IAaveOracle public oracle;
  IMockL2Pool public pool;
  uint256 public constant MAX_PRICE_DEVIATION_BPS = 500; // 5% max deviation

  constructor(address oracleAddress, address poolAddress) {
    oracle = IAaveOracle(oracleAddress);
    pool = IMockL2Pool(poolAddress);
  }

  function triggers() public view override {
    // Register triggers for core operations that affect oracle prices
    registerCallTrigger(this.assertBorrowPriceDeviation.selector, pool.borrow.selector);
    registerCallTrigger(this.assertSupplyPriceDeviation.selector, pool.supply.selector);
    registerCallTrigger(
      this.assertLiquidationPriceDeviation.selector,
      pool.liquidationCall.selector
    );
    // Register triggers for price consistency checks (ORACLE_INVARIANT_B)
    registerCallTrigger(this.assertBorrowPriceConsistency.selector, pool.borrow.selector);
    registerCallTrigger(this.assertSupplyPriceConsistency.selector, pool.supply.selector);
    registerCallTrigger(this.assertWithdrawPriceConsistency.selector, pool.withdraw.selector);
    registerCallTrigger(this.assertRepayPriceConsistency.selector, pool.repay.selector);
    registerCallTrigger(
      this.assertLiquidationPriceConsistency.selector,
      pool.liquidationCall.selector
    );
    registerCallTrigger(this.assertFlashloanPriceConsistency.selector, pool.flashLoan.selector);
    registerCallTrigger(
      this.assertFlashloanSimplePriceConsistency.selector,
      pool.flashLoanSimple.selector
    );
  }

  /*/////////////////////////////////////////////////////////////////////////////////////////////
        ORACLE_INVARIANT_A: getAssetPrice must never revert
        NOTE: This invariant cannot be tested with assertions because:
        1. We cannot force oracle failures in a controlled way
        2. Oracle failures are external to the protocol and depend on price feed implementations
        3. Testing this would require mocking oracle failures, which defeats the purpose
        4. This invariant is better tested at the oracle implementation level
    /////////////////////////////////////////////////////////////////////////////////////////////*/

  /*/////////////////////////////////////////////////////////////////////////////////////////////
        Don't allow price deviation before / after a tx to be more than 5%
    /////////////////////////////////////////////////////////////////////////////////////////////*/

  /**
   * @notice Asserts that the price of an asset has not deviated by more than the maximum allowed percentage during borrow
   */
  function assertBorrowPriceDeviation() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));

      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      uint16 assetId = uint16(uint256(args));
      address asset = pool.getReserveAddressById(assetId);

      if (asset != address(0)) {
        _checkPriceDeviation(asset, 'Borrow price deviation exceeds maximum allowed');
      }
    }
  }

  /**
   * @notice Asserts that the price of an asset has not deviated by more than the maximum allowed percentage during supply
   */
  function assertSupplyPriceDeviation() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.supply.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));

      // Decode L2Pool supply parameters: assetId (16 bits) + amount (128 bits) + referralCode (16 bits)
      uint16 assetId = uint16(uint256(args));
      address asset = pool.getReserveAddressById(assetId);

      if (asset != address(0)) {
        _checkPriceDeviation(asset, 'Supply price deviation exceeds maximum allowed');
      }
    }
  }

  /**
   * @notice Asserts that the price of collateral and debt assets has not deviated by more than the maximum allowed percentage during liquidation
   */
  function assertLiquidationPriceDeviation() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      pool.liquidationCall.selector
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, ) = abi.decode(callInputs[i].input, (bytes32, bytes32));

      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      uint16 collateralAssetId = uint16(uint256(args1));
      uint16 debtAssetId = uint16(uint256(args1) >> 16);

      address collateralAsset = pool.getReserveAddressById(collateralAssetId);
      address debtAsset = pool.getReserveAddressById(debtAssetId);

      if (collateralAsset != address(0)) {
        _checkPriceDeviation(collateralAsset, 'Collateral price deviation exceeds maximum allowed');
      }
      if (debtAsset != address(0)) {
        _checkPriceDeviation(debtAsset, 'Debt price deviation exceeds maximum allowed');
      }
    }
  }

  /**
   * @notice Internal helper to check price deviation for an asset
   * @param asset The address of the asset to check
   * @param errorMessage The error message to use if deviation is too high
   */
  function _checkPriceDeviation(address asset, string memory errorMessage) internal {
    // Get price before
    ph.forkPreState();
    uint256 prePrice = oracle.getAssetPrice(asset);

    // Get price after
    ph.forkPostState();
    uint256 postPrice = oracle.getAssetPrice(asset);

    // Skip check if prices are 0
    require(prePrice != 0 && postPrice != 0, 'Oracle returned zero price');

    // Calculate deviation in basis points
    uint256 deviation;
    if (postPrice > prePrice) {
      deviation = ((postPrice - prePrice) * 10000) / prePrice;
    } else {
      deviation = ((prePrice - postPrice) * 10000) / prePrice;
    }

    // Check deviation is within limits
    require(deviation <= MAX_PRICE_DEVIATION_BPS, errorMessage);
  }

  /*/////////////////////////////////////////////////////////////////////////////////////////////
        ORACLE_INVARIANT_B: The price feed should never return different prices 
        when called multiple times in a single tx
        See tests/invariants/specs/InvariantsSpec.t.sol
    /////////////////////////////////////////////////////////////////////////////////////////////*/

  /**
   * @notice Asserts that the oracle price remains consistent during borrow operations
   */
  function assertBorrowPriceConsistency() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));

      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      uint16 assetId = uint16(uint256(args));
      address asset = pool.getReserveAddressById(assetId);

      if (asset != address(0)) {
        _checkPriceConsistency(asset);
      }
    }
  }

  /**
   * @notice Asserts that the oracle price remains consistent during supply operations
   */
  function assertSupplyPriceConsistency() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.supply.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));

      // Decode L2Pool supply parameters: assetId (16 bits) + amount (128 bits) + referralCode (16 bits)
      uint16 assetId = uint16(uint256(args));
      address asset = pool.getReserveAddressById(assetId);

      if (asset != address(0)) {
        _checkPriceConsistency(asset);
      }
    }
  }

  /**
   * @notice Asserts that the oracle price remains consistent during withdraw operations
   */
  function assertWithdrawPriceConsistency() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.withdraw.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));

      // Decode L2Pool withdraw parameters: assetId (16 bits) + amount (128 bits) + to (160 bits)
      uint16 assetId = uint16(uint256(args));
      address asset = pool.getReserveAddressById(assetId);

      if (asset != address(0)) {
        _checkPriceConsistency(asset);
      }
    }
  }

  /**
   * @notice Asserts that the oracle price remains consistent during repay operations
   */
  function assertRepayPriceConsistency() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));

      // Decode L2Pool repay parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits)
      uint16 assetId = uint16(uint256(args));
      address asset = pool.getReserveAddressById(assetId);

      if (asset != address(0)) {
        _checkPriceConsistency(asset);
      }
    }
  }

  /**
   * @notice Asserts that the oracle price remains consistent during liquidation operations
   */
  function assertLiquidationPriceConsistency() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      pool.liquidationCall.selector
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, ) = abi.decode(callInputs[i].input, (bytes32, bytes32));

      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      uint16 collateralAssetId = uint16(uint256(args1));
      uint16 debtAssetId = uint16(uint256(args1) >> 16);

      address collateralAsset = pool.getReserveAddressById(collateralAssetId);
      address debtAsset = pool.getReserveAddressById(debtAssetId);

      if (collateralAsset != address(0)) {
        _checkPriceConsistency(collateralAsset);
      }
      if (debtAsset != address(0)) {
        _checkPriceConsistency(debtAsset);
      }
    }
  }

  /**
   * @notice Asserts that the oracle price remains consistent during flashloan operations
   */
  function assertFlashloanPriceConsistency() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.flashLoan.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode flashLoan parameters: (address receiverAddress, address[] assets, uint256[] amounts, uint256[] modes, address onBehalfOf, bytes params, uint16 referralCode)
      (, address[] memory assets, , , , , ) = abi.decode(
        callInputs[i].input,
        (address, address[], uint256[], uint256[], address, bytes, uint16)
      );

      // Check price consistency for all assets in the flashloan
      for (uint256 j = 0; j < assets.length; j++) {
        if (assets[j] != address(0)) {
          _checkPriceConsistency(assets[j]);
        }
      }
    }
  }

  /**
   * @notice Asserts that the oracle price remains consistent during flashloanSimple operations
   */
  function assertFlashloanSimplePriceConsistency() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      pool.flashLoanSimple.selector
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode flashLoanSimple parameters: (address receiverAddress, address asset, uint256 amount, bytes params, uint16 referralCode)
      (, address asset, , , ) = abi.decode(
        callInputs[i].input,
        (address, address, uint256, bytes, uint16)
      );

      if (asset != address(0)) {
        _checkPriceConsistency(asset);
      }
    }
  }

  /**
   * @notice Internal helper to check price consistency for an asset
   * @param asset The address of the asset to check
   */
  function _checkPriceConsistency(address asset) internal {
    // Get price at start of transaction
    ph.forkPreState();
    uint256 initialPrice = oracle.getAssetPrice(asset);

    // Get price at end of transaction
    ph.forkPostState();
    uint256 finalPrice = oracle.getAssetPrice(asset);

    // Skip check if prices are 0
    require(initialPrice != 0 && finalPrice != 0, 'Oracle returned zero price');

    // Check prices are exactly equal
    require(initialPrice == finalPrice, 'Oracle price changed during transaction');
  }

  function assertPriceDeviationAllCalls() external {
    // It would be ideal to be able to read the price from a storage slot
    // and get all changes in price to make sure they're the same, but the way
    // the oracle is implemented, it's not possible to do this.
    // Good assertions for Oracles like Chainlink is high priority and we're
    // actively working on it.
  }
}
