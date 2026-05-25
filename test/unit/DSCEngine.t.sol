//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
//import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol"; Update mock location
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {MockMoreDebtDSC} from "../../test/mocks/MockMoreDebtDSC.sol";
import {MockFailedMintDSC} from "../../test/mocks/MockFailedMintDSC.sol";
import {MockFailedTransfer} from "../../test/mocks/MockFailedTransfer.sol";
import {MockFailedTransferFrom} from "../../test/mocks/MockFailedTransferFrom.sol";
import {Test, stdError} from "forge-std/Test.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address weth;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;
    uint256 collateralToCover = 20 ether;

    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant DEBT_TO_COVER = 1000 ether;
    uint256 public constant LIQUIDATOR_DSC_TO_MINT = 1000 ether;
    uint256 public constant AMOUNT_DSC_TO_MINT = 9000 ether;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    function setUp() public {
        deployer = new DeployDSC();
        (dsce, dsc, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        if (block.chainid == 31337) {
            vm.deal(USER, STARTING_ERC20_BALANCE);
            vm.deal(LIQUIDATOR, STARTING_ERC20_BALANCE);
        }

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
    }

    //////////////////////
    ///Constructor Tests//
    //////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ////////////////
    ///Price Tests//
    ////////////////

    function testGetUsdValue() public view {
        //15e18 * 2000/ETH = 30 000e18
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    function testGetTokenAmountFromUsdReturnsZeroIfPriceIsZero() public {
        //Arrange
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(0);

        //Act
        uint256 tokenAmount = dsce.getTokenAmountFromUsd(weth, 100 ether);

        //Assert
        assertEq(tokenAmount, 0);
    }

    ////////////////////////////
    ///depositCollateral Tests//
    ///////////////////////////

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralValueInUsd = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedCollateralValueInUsd);
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", USER, 100e18);
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(randToken)));
        dsce.depositCollateral(address(randToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfTransferFromFails() public {
        //how can simulate transfer failing without token simulation?
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockCollateralToken = new MockFailedTransferFrom();
        tokenAddresses = [address(mockCollateralToken)];
        priceFeedAddresses = [ethUsdPriceFeed];

        //DSCEngine receives the third parameter as dscAddress, not tokenAddress used as collateral
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
        mockCollateralToken.mint(USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        ERC20Mock(address(mockCollateralToken)).approve(address(mockDsce), AMOUNT_COLLATERAL);

        //Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockCollateralToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testGetAccountCollateralValueIsRecorded() public depositedCollateral {
        uint256 userCollateralBalance = dsce.getAccountCollateralValue(USER);
        uint256 expectedCollateralValueInUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);

        assertEq(userCollateralBalance, expectedCollateralValueInUsd);
    }

    function testUserBalanceDecreasesAfterDeposit() public {
        uint256 userStartingBalance = STARTING_ERC20_BALANCE;

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 userEndingBalance = ERC20Mock(weth).balanceOf(USER);

        assertEq(userEndingBalance, userStartingBalance - AMOUNT_COLLATERAL);
    }

    function testEmitsCollateralDepositedEvent() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, false, address(dsce));
        emit DSCEngine.CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testDsceReceivesCollateralTokens() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 dsceBalance = ERC20Mock(weth).balanceOf(address(dsce));
        assertEq(dsceBalance, AMOUNT_COLLATERAL);
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    //////////////////////////////
    ///Deposit and MintDSC Tests//
    //////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);

        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepostedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    // This test needs it's own custom setup
    function testRevertsIfMintsFails() public {
        //Arrange - set up
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        address owner = mockDsc.owner();
        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));

        //Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    ///////////////////
    ///MintDSC Tests//
    //////////////////

    function testCanMintDsc() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(amountToMint);
        vm.stopPrank();

        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, amountToMint);
    }

    function testRevertsIfMintingZeroDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();

        vm.startPrank(USER);

        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, amountCollateral));

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCannotMintWithoutDepositingCollateral() public {
        vm.startPrank(USER);

        //Do not deposit collateral; do not approve anything!
        //Try to mint - should revert because healthFactor will be broken
        //with 0 collateral the health factor will be 0

        uint256 expectedHealthFactor = dsce.calculateHealthFactor(amountToMint, 0);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    ///////////////////
    ///BurnDsc Tests//
    //////////////////

    function testCanBurnDsc() public {
        uint256 amountDscToBurn = 10 ether;

        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(amountDscToBurn);

        // approve DSCEngine to take DSC from USER
        dsc.approve(address(dsce), amountDscToBurn);

        dsce.burnDsc(amountDscToBurn);
        vm.stopPrank();

        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, 0);
    }

    function testRevertsIfBurningZeroDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(10 ether);

        // approve DSCEngine to take DSC from USER
        dsc.approve(address(dsce), 10 ether);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfBurningMoreThanMinted() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(10 ether);

        vm.expectRevert(stdError.arithmeticError);
        dsce.burnDsc(11 ether);
        vm.stopPrank();
    }

    //////////////////
    ///redeem Tests//
    /////////////////

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        uint256 userBalanceBeforeRedeem = dsce.getCollateralBalanceOfUser(USER, weth);
        assertEq(userBalanceBeforeRedeem, amountCollateral);
        dsce.redeemCollateral(weth, amountCollateral);
        uint256 userBalanceAfterRedeem = dsce.getCollateralBalanceOfUser(USER, weth);
        assertEq(userBalanceAfterRedeem, 0);
        vm.stopPrank();
    }

    function testEmitsCollateralRedeemedEvent() public depositedCollateral {
        vm.startPrank(USER);

        vm.expectEmit(true, true, true, false, address(dsce));
        emit DSCEngine.CollateralRedeemed(USER, USER, weth, 5 ether);
        dsce.redeemCollateral(weth, 5 ether);

        vm.stopPrank();
    }

    function testRevertsIfRedeemingZeroCollateral() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsIfTransferFails() public {
        //Arrange - Set up
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        address owner = mockDsc.owner();
        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));

        //Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        //Act-Assert
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testMustRedeemMOreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsc.approve(address(dsce), amountToMint);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.redeemCollateralForDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    ///healthFactor Tests//
    ///////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dsce.getHealthFactor(USER);
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 eth = $18
        //Drop ETH price to make USER undercollateralized
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dsce.getHealthFactor(USER);
        assert(userHealthFactor == 0.9 ether);
    }

    //////////////////////
    ///liquidation Tests/
    /////////////////////

    function testCanLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 eth = $18
        //Drop ETH price to make USER undercollateralized
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dsce.getHealthFactor(USER);

        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.liquidate(weth, USER, amountToMint); //covering the whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMint)
            + ((dsce.getTokenAmountFromUsd(weth, amountToMint) * dsce.getLiquidationBonus())
                / dsce.getLiquidationPrecision());
        uint256 hardCodedExpected = 10 ether + expectedWeth; //liquidator had 10 ether, then deposited 20 ether, then got back the collateral from liquidation, so should have 10 + expectedWeth - 20
        assertEq(liquidatorWethBalance, hardCodedExpected);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        //Get how much WETH the user lost
        uint256 amountLiquidated = dsce.getTokenAmountFromUsd(weth, amountToMint)
            + ((dsce.getTokenAmountFromUsd(weth, amountToMint) * dsce.getLiquidationBonus())
                / dsce.getLiquidationPrecision());

        uint256 usdAmountLiquidated = dsce.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = dsce.getUsdValue(weth, amountCollateral) - usdAmountLiquidated;

        (, uint256 userCollateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testGetBonusCollateralAfterLiquidation() public {
        //Drop ETH price to make USER undercollateralized
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1000e8);

        uint256 bonusCollateral = dsce.getBonusCollateral(weth, DEBT_TO_COVER);

        uint256 expectedTokenAmountFromDebtCovered = dsce.getTokenAmountFromUsd(weth, DEBT_TO_COVER);

        uint256 expectedBonusCollateral = (expectedTokenAmountFromDebtCovered * 10) / 100;
        assertEq(bonusCollateral, expectedBonusCollateral);
    }

    function testRevertsIfHealthFactorNotImprovedAfterLiquidation() public {
        //Arrange - Set up
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));

        address owner = mockDsc.owner();
        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));

        //1. USER scenario: deposit collateral and mint DSC
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        //2. LIQUIDATOR scenario: deposit collateral and mint DSC
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        mockDsc.approve(address(mockDsce), debtToCover);
        //Act
        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        //Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockDsce.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    /////////////////////////////////
    // View & Pure Function Tests //
    ///////////////////////////////

    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = dsce.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = dsce.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = dsce.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedCollateralValueInUsd = dsce.getUsdValue(weth, amountCollateral);
        assertEq(collateralValueInUsd, expectedCollateralValueInUsd);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 userCollateralBalance = dsce.getCollateralBalanceOfUser(USER, weth);
        assertEq(userCollateralBalance, amountCollateral);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralValue = dsce.getAccountCollateralValue(USER);
        uint256 expectedCollateralValueInUsd = dsce.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValueInUsd);
    }

    function testGetDsc() public view {
        address dscAddress = dsce.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public view {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dsce.getLiquidationPrecision();
        assertEq(expectedLiquidationPrecision, actualLiquidationPrecision);
    }
}
