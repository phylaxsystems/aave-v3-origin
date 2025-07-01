// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title BorrowingInvariantAssertions Tests
 * @notice This test file uses the real Aave V3 protocol to verify that our assertions
 *         correctly pass when the protocol behaves as expected. It ensures that our
 *         assertions don't revert when they shouldn't, validating that our invariant
 *         checks are not overly restrictive.
 *
 *         For example, it verifies that the liability decrease assertion passes when
 *         a user successfully repays their debt, as the real protocol correctly
 *         decreases the user's debt.
 */
import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {BaseInvariants} from '../src/BaseInvariants.a.sol';
import {IMockL2Pool} from '../src/IMockL2Pool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';
import {L2Encoder} from '../../src/contracts/helpers/L2Encoder.sol';

contract TestBorrowingInvariantAssertions is CredibleTest, Test, TestnetProcedures {
  IMockL2Pool public pool;
  BaseInvariants public assertions;
  L2Encoder public l2Encoder;
  address public user;
  address public asset;
  IERC20 public underlying;
  IERC20 public variableDebtToken;
  string public constant ASSERTION_LABEL = 'DebtSumInvariant';

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
    assertions = new BaseInvariants(address(pool), address(underlying));

    // Get variable debt token
    (, , address variableDebtUSDX) = contracts.protocolDataProvider.getReserveTokensAddresses(
      asset
    );
    variableDebtToken = IERC20(variableDebtUSDX);

    // Set up fresh user with collateral
    deal(asset, user, 2000e6);
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral using L2Pool encoding
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 1000e6, 0);
    pool.supply(supplyArgs);
    vm.stopPrank();
  }

  function testAssertionBorrowBug() public {
    // For testing purposes, we have introduced a bug in the borrow function
    // When trying to borrow exactly 333e6, the user will receive double the amount
    // and the total debt will not be correctly updated

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BaseInvariants).creationCode,
      abi.encode(address(pool), address(underlying))
    );

    vm.prank(user);
    vm.expectRevert('Assertions Reverted');
    // This should fail assertions because the user will receive double tokens

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 333e6, 2, 0);

    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
  }

  function testAssertionBorrowNormal() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BaseInvariants).creationCode,
      abi.encode(address(pool), address(underlying))
    );

    vm.prank(user);
    // This should NOT fail assertions because the borrow amount is not the magic number

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 100e6, 2, 0);

    vm.prank(user);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
  }

  function testBorrowInvariantManual() public {
    vm.startPrank(user);

    // Get aToken address for the asset
    (address aTokenAddr, , ) = contracts.protocolDataProvider.getReserveTokensAddresses(asset);
    IERC20 aToken = IERC20(aTokenAddr);

    // --- Normal borrow: should work as expected ---
    uint256 beforeDebtTotal = variableDebtToken.totalSupply();
    uint256 beforeATokenTotal = aToken.totalSupply();
    emit log_named_uint('aToken totalSupply before normal borrow', beforeATokenTotal);
    emit log_named_uint('DebtToken totalSupply before normal borrow', beforeDebtTotal);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 100e6, 2, 0);
    pool.borrow(borrowArgs);

    uint256 afterDebtTotal = variableDebtToken.totalSupply();
    uint256 afterATokenTotal = aToken.totalSupply();
    emit log_named_uint('aToken totalSupply after normal borrow', afterATokenTotal);
    emit log_named_uint('DebtToken totalSupply after normal borrow', afterDebtTotal);
    emit log_named_uint('aToken delta (normal)', afterATokenTotal - beforeATokenTotal);
    emit log_named_uint('DebtToken delta (normal)', afterDebtTotal - beforeDebtTotal);
    assertEq(
      afterATokenTotal - beforeATokenTotal,
      0,
      'aToken totalSupply should not change on borrow'
    );
    assertEq(
      afterDebtTotal - beforeDebtTotal,
      100e6,
      'DebtToken totalSupply should increase by borrowed amount'
    );
    vm.stopPrank();
  }
}
