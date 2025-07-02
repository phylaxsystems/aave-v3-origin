// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {BorrowLogicErrorAssertion} from '../src/BorrowLogicErrorAssertion.a.sol';
import {IMockL2Pool} from '../src/IMockL2Pool.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';
import {L2Encoder} from '../../src/contracts/helpers/L2Encoder.sol';

// This test is used to test the borrow logic error assertion.
// There's a bug in the borrow function that allows the user to borrow more than the underlying token balance.

contract TestBorrowLogicErrorAssertion is CredibleTest, Test, TestnetProcedures {
  IMockL2Pool public pool;
  BorrowLogicErrorAssertion public assertions;
  L2Encoder public l2Encoder;
  address public user;
  address public asset;
  IERC20 public underlying;
  IERC20 public variableDebtToken;
  string public constant ASSERTION_LABEL = 'BorrowLogicErrorAssertion';

  function setUp() public {
    // Initialize test environment with real contracts (L2 enabled for L2Encoder)
    initL2TestEnvironment();

    // Set up user and get pool reference
    user = alice;
    pool = IMockL2Pool(report.poolProxy);
    asset = tokenList.usdx;
    underlying = IERC20(asset);

    // Set up L2Encoder for creating compact parameters
    l2Encoder = L2Encoder(report.l2Encoder);

    // Deploy assertions contract
    assertions = new BorrowLogicErrorAssertion(address(pool), asset);

    // Get variable debt token
    (, , address variableDebtUSDX) = contracts.protocolDataProvider.getReserveTokensAddresses(
      asset
    );
    variableDebtToken = IERC20(variableDebtUSDX);
  }

  function testAssertionBorrowBug() public {
    // For testing purposes, we have introduced a bug in the borrow function
    // When trying to borrow exactly 333e6, the user will receive double the amount
    // and the total debt will not be correctly updated

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BorrowLogicErrorAssertion).creationCode,
      abi.encode(address(pool), asset)
    );

    // Set up fresh user with collateral
    deal(asset, user, 20000e6);
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);

    // Create L2Pool compact parameters for supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    pool.supply(supplyArgs);

    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 333e6, 2, 0);

    vm.expectRevert('Assertions Reverted');
    // This should fail assertions because the user will receive double tokens
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  function testAssertionBorrowNormal() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BorrowLogicErrorAssertion).creationCode,
      abi.encode(address(pool), asset)
    );

    // Set up fresh user with collateral
    deal(asset, user, 2000e6);
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);

    // Create L2Pool compact parameters for supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 1000e6, 0);
    pool.supply(supplyArgs);

    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 100e6, 2, 0);

    // This should NOT fail assertions because the borrow amount is not the magic number
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }
}
