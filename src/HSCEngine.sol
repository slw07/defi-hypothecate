//SPDX-License-Identifier:MIT

pragma solidity 0.8.19;

import {HypothecateStableCoin} from "./HypothecateStableCoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HSCEngineErrorsAndEvents} from "./lib/HSCEngineErrorsAndEvents.sol";

contract HSCEngine is ReentrancyGuard, HSCEngineErrorsAndEvents {
    HypothecateStableCoin hsc; //稳定币
    mapping(address => address) priceFeedMapping; //喂价地址映射
    address[] tokenAddresses; //支持的抵押代币种类
    mapping(address => mapping(address => uint256)) collateralMapping; //所有用户的抵押列表
    mapping(address => uint256) mintHscMapping; //每个用户铸造的稳定币

    /*
     * __tokenAddress  支持的代币代币地址
     * __priceFeedAddress  代币对应的喂价地址
     * __hsc  稳定币地址
     */
    constructor(address[] memory __tokenAddress, address[] memory __priceFeedAddress, address __hsc) {
        if (__tokenAddress.length != __priceFeedAddress.length) {
            revert HSCEngine_PriceFeedNotEqual();
        }
        for (uint256 i = 0; i < __tokenAddress.length; i++) {
            priceFeedMapping[__tokenAddress[i]] = __priceFeedAddress[i];
            tokenAddresses.push(__tokenAddress[i]);
        }
        hsc = HypothecateStableCoin(__hsc);
    }

    /*
     * 抵押代币并获取稳定币
     * tokenAddress  代币地址
     * depositAmount  抵押的代币数量
     * hscAmount   稳定币数量
     */
    function depositCollateralAndMintHsc(address tokenAddress, uint256 depositAmount, uint256 hscAmount) external {
        //抵押代币
        depositCollateral(tokenAddress, depositAmount);
        //铸造稳定币
        mintHsc(hscAmount);
    }

    /*
     * 抵押代币
     * tokenAddress  抵押代币的地址
     * depositAmount 抵押代币的数量
     *
     */
    function depositCollateral(address tokenAddress, uint256 depositAmount) public nonReentrant {
        if (priceFeedMapping[tokenAddress] == address(0)) {
            revert HSCEngine_tokenNotExists();
        }
        if (depositAmount < 0) {
            revert HSCEngine_DepositAmountMoreThanZero();
        }
        //保存所有用户抵押的代表数量
        collateralMapping[msg.sender][tokenAddress] += depositAmount;
        emit HSCEngine_DepositCollateral(msg.sender, tokenAddress, depositAmount);
        bool success = IERC20(tokenAddress).transferFrom(msg.sender, address(this), depositAmount);
        if (!success) {
            revert HSCEngine_TransferFailed();
        }
    }

    /**
     * 铸造稳定币HSC
     * @param hscAmount 稳定币数量
     */
    function mintHsc(uint256 hscAmount) public nonReentrant {
        if (hscAmount < 0) {
            revert HSCEngine_MintAmountMoreThanZero();
        }
        mintHscMapping[msg.sender] = hscAmount;
        bool success = hsc.mint(msg.sender, hscAmount);
        if (success) {
            hsc.transferFrom(address(this), msg.sender, hscAmount);
        }
        emit HSCEngine_DscMint(msg.sender, hscAmount);
    }

    /**
     * 赎回抵押
     * tokenCollateralAddress  抵押代币地址
     * collateralAmount  抵押代币数量
     * burnHscAmount  销毁代币数量
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 collateralAmount, uint256 burnHscAmount)
        public
    {
        redeemCollateral(tokenCollateralAddress, collateralAmount);
        burnHsc(burnHscAmount);
    }

    /*
     * 退回用户抵押的代币
     * tokenCollateralAddress 抵押代币地址
     * collateralAmount  抵押代币数量
     *
     ****/
    function redeemCollateral(address tokenCollateralAddress, uint256 collateralAmount) public nonReentrant {
        if (collateralMapping[msg.sender][tokenCollateralAddress] < 0) {
            revert HSCEngine_CollateralTokenNotEnough();
        }
        if (collateralMapping[msg.sender][tokenCollateralAddress] < collateralAmount) {
            revert HSCEngine_CollateralAmountTooLarge();
        }
        collateralMapping[msg.sender][tokenCollateralAddress] -= collateralAmount;

        bool success = IERC20(tokenCollateralAddress).transferFrom(address(this), msg.sender, collateralAmount);
        if (!success) {
            revert HSCEngine_RedeemTokenTransferFailed();
        }
        emit HSCEngine_RedeemCollateral(msg.sender, tokenCollateralAddress, collateralAmount);
    }

    /**
     * 用户退回稳定币，合约销毁用户退回的稳定币
     * burnHscAmount  销毁的稳定币数量
     *
     */
    function burnHsc(uint256 burnHscAmount) public nonReentrant {
        mintHscMapping[msg.sender] -= burnHscAmount;

        bool success = hsc.transferFrom(msg.sender, address(this), burnHscAmount);
        if (!success) {
            revert HSCEngine_RedeemHscTransferFailed();
        }
        hsc.burn(burnHscAmount);
        emit HSCEngine_BurnDesc(msg.sender, burnHscAmount);
    }

    /**
     * 清算
     * collateral  抵押代币地址
     * user  用户地址
     * debtToCover  销毁稳定币的数量用来偿还债务
     */
    function liquidate(address collateral, address user, uint256 debtToCover) public {
        uint256 userHealthFactor = healthFactor(user);
        if (userHealthFactor >= 1e18) {
            revert HSCEngine_HealthFactoryOk();
        }

        uint256 tokenAmountFromDebtCoverd = getTokenAmountFromUsd(collateral, debtToCover);

        uint256 bonusCollateral = (tokenAmountFromDebtCoverd * 10) / 100;
        // Burn DSC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        _redeemCollateral(collateral, tokenAmountFromDebtCoverd + bonusCollateral, user, msg.sender);
        burnHsc(debtToCover);

        uint256 endingUserHealthFactor = healthFactor(user);
        if (endingUserHealthFactor <= userHealthFactor) {
            revert HSCEngine_HealthFactorNotImproved();
        }
        // revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * 退回抵押代币
     * tokenCollateralAddress 抵押代币地址
     * amountCollateral  抵押代币数量
     * from 发送账户
     * to  接受账户
     */
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        public
        nonReentrant
    {
        collateralMapping[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert HSCEngine_TransferFailed();
        }
    }

    /**
     * 获取抵押代币的数量
     * token 抵押代币地址
     * usdAmountInWei  美元数量
     *
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedMapping[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((usdAmountInWei * 1e18) / (uint256(price) * 1e10));
    }

    /**
     * 获取用户的健康值，是否达到清算条件
     * user 用户地址
     */
    function healthFactor(address user) public view returns (uint256) {
        (uint256 totalHsc, uint256 collateralValueInUsd) = getAccountInfo(user);
        return calculateHealthFactor(totalHsc, collateralValueInUsd);
    }

    /**
     * 计算用户的健康因素
     * totalHsc  用户抵押总共获得的稳定币
     * callateralValueInUsd   用户抵押品的总美元价值
     *
     */
    function calculateHealthFactor(uint256 totalHsc, uint256 collateralValueInUsd) public pure returns (uint256) {
        if (totalHsc == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * 50) / 100;
        return (collateralAdjustedForThreshold * 1e18) / totalHsc;
    }

    /**
     * 获取指定用户抵押获得的所有稳定币和抵押代币的总美元价值
     * user   用户地址
     */
    function getAccountInfo(address user) public view returns (uint256 totalHsc, uint256 collateralValueInUsd) {
        totalHsc = mintHscMapping[user];
        collateralValueInUsd = getCollateralValue(user);
    }

    /**
     * 计算指定用户下所有的抵押代币的美元价值
     *  user  用户地址
     *
     */
    function getCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            address token = tokenAddresses[i];
            uint256 amount = collateralMapping[user][token];
            totalCollateralValueInUsd += calculateTokenValueInUsd(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    /**
     *  chainlink的priceFeed计算代币兑换的美元数量
     * tokenAddress  代币地址
     * amount  代币数量
     */
    function calculateTokenValueInUsd(address tokenAddress, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface aggregator = AggregatorV3Interface(priceFeedMapping[tokenAddress]);
        (, int256 price,,,) = aggregator.latestRoundData();
        return uint256(price) * amount;
    }

    /**
     *
     * 返回指定用户下指定token的抵押数量
     */
    function getTokenAccount(address user, address token) external view returns (uint256) {
        return collateralMapping[user][token];
    }
}
