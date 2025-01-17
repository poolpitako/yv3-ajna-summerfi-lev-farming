// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC20Pool} from "@ajna-core/interfaces/pool/erc20/IERC20Pool.sol";
import {IWETH} from "../IWETH.sol";

interface IAjnaPoolUtilsInfo {
    function priceToIndex(uint256 price_) external pure returns (uint256);

    function borrowerInfo(address pool_, address borrower_)
        external
        view
        returns (
            uint256 debt_,
            uint256 collateral_,
            uint256 index_
        );

    function poolPricesInfo(address ajnaPool_)
        external
        view
        returns (
            uint256 hpb_,
            uint256 hpbIndex_,
            uint256 htp_,
            uint256 htpIndex_,
            uint256 lup_,
            uint256 lupIndex_
        );

    function lpToQuoteTokens(
        address ajnaPool_,
        uint256 lp_,
        uint256 index_
    ) external view returns (uint256 quoteAmount_);

    function bucketInfo(address ajnaPool_, uint256 index_)
        external
        view
        returns (
            uint256 price_,
            uint256 quoteTokens_,
            uint256 collateral_,
            uint256 bucketLP_,
            uint256 scale_,
            uint256 exchangeRate_
        );
}

interface IAccountGuard {
    function owners(address) external view returns (address);

    function owner() external view returns (address);

    function setWhitelist(address target, bool status) external;

    function canCall(address proxy, address operator)
        external
        view
        returns (bool);

    function permit(
        address caller,
        address target,
        bool allowance
    ) external;

    function isWhitelisted(address target) external view returns (bool);

    function isWhitelistedSend(address target) external view returns (bool);
}

contract AjnaProxyActions {
    IAjnaPoolUtilsInfo public immutable poolInfoUtils;
    IERC20 public immutable ajnaToken;
    address public immutable WETH;
    address public immutable GUARD;
    address public immutable deployer;
    /* 
  This configuration is applicable across all Layer 2 (L2) networks. However, on the Ethereum mainnet, 
  we continue to use 'Ajna_rc13'. Due to the nature of 'string' data type in Solidity, it cannot be 
  declared as 'immutable' and initialized within the constructor. 
  */
    string public constant ajnaVersion = "Ajna_rc14";

    using SafeERC20 for IERC20;

    constructor(
        IAjnaPoolUtilsInfo _poolInfoUtils,
        IERC20 _ajnaToken,
        address _WETH,
        address _GUARD
    ) {
        require(
            address(_poolInfoUtils) != address(0),
            "apa/pool-info-utils-zero-address"
        );
        require(
            address(_ajnaToken) != address(0) || block.chainid != 1,
            "apa/ajna-token-zero-address"
        );
        require(_WETH != address(0), "apa/weth-zero-address");
        require(_GUARD != address(0), "apa/guard-zero-address");
        poolInfoUtils = _poolInfoUtils;
        ajnaToken = _ajnaToken;
        WETH = _WETH;
        GUARD = _GUARD;
        deployer = msg.sender;
    }

    /**
     * @dev Emitted once an Operation has completed execution
     * @param name Name of the operation
     **/
    event ProxyActionsOperation(bytes32 indexed name);

    /**
     * @dev Emitted when a new position is created
     * @param proxyAddress The address of the newly created position proxy contract
     * @param protocol The name of the protocol associated with the position
     * @param positionType The type of position being created (e.g. borrow or earn)
     * @param collateralToken The address of the collateral token being used for the position
     * @param debtToken The address of the debt token being used for the position
     **/
    event CreatePosition(
        address indexed proxyAddress,
        string protocol,
        string positionType,
        address collateralToken,
        address debtToken
    );

    function _send(address token, uint256 amount) internal {
        if (token == WETH) {
            IWETH(WETH).withdraw(amount);
            payable(msg.sender).transfer(amount);
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
    }

    function _pull(address token, uint256 amount) internal {
        if (token == WETH) {
            IWETH(WETH).deposit{value: amount}();
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _stampLoan(IERC20Pool pool, bool stamploanEnabled) internal {
        if (stamploanEnabled) {
            pool.stampLoan();
        }
    }

    /**
     *  @notice Called internally to add an amount of credit at a specified price bucket.
     *  @param  pool         Address of the Ajana Pool.
     *  @param  amount       The maximum amount of quote token to be moved by a lender.
     *  @param  price        The price the bucket to which the quote tokens will be added.
     *  @dev price of uint (10**decimals) collateral token in debt token (10**decimals) with 3 decimal points for instance
     *  @dev 1WBTC = 16,990.23 USDC   translates to: 16990230
     */
    function _supplyQuote(
        IERC20Pool pool,
        uint256 amount,
        uint256 price
    ) internal returns (uint256 bucketLP, uint256 addedAmount) {
        address debtToken = pool.quoteTokenAddress();
        _pull(debtToken, amount);
        uint256 index = convertPriceToIndex(price);
        IERC20(debtToken).approve(address(pool), amount);
        (bucketLP, addedAmount) = pool.addQuoteToken(
            amount * pool.quoteTokenScale(),
            index,
            block.timestamp + 1
        );
    }

    /**
     *  @notice Called internally to move max amount of credit from a specified price bucket to another specified price bucket.
     *  @param  pool         Address of the Ajana Pool.
     *  @param  oldPrice        The price of the bucket  from which the quote tokens will be removed.
     *  @param  newPrice     The price of the bucket to which the quote tokens will be added.
     */
    function _moveQuote(
        IERC20Pool pool,
        uint256 oldPrice,
        uint256 newPrice
    ) internal {
        uint256 oldIndex = convertPriceToIndex(oldPrice);
        pool.moveQuoteToken(
            type(uint256).max,
            oldIndex,
            convertPriceToIndex(newPrice),
            block.timestamp + 1
        );
    }

    /**
     *  @notice Called internally to remove an amount of credit at a specified price bucket.
     *  @param  pool         Address of the Ajana Pool.
     *  @param  amount       The maximum amount of quote token to be moved by a lender.
     *  @param  price        The price the bucket to which the quote tokens will be added.
     *  @dev price of uint (10**decimals) collateral token in debt token (10**decimals) with 3 decimal points for instance
     *  @dev 1WBTC = 16,990.23 USDC   translates to: 16990230
     */
    function _withdrawQuote(
        IERC20Pool pool,
        uint256 amount,
        uint256 price
    ) internal {
        address debtToken = pool.quoteTokenAddress();
        uint256 index = convertPriceToIndex(price);
        uint256 withdrawnBalanceWAD;
        if (amount == type(uint256).max) {
            (withdrawnBalanceWAD, ) = pool.removeQuoteToken(
                type(uint256).max,
                index
            );
        } else {
            (withdrawnBalanceWAD, ) = pool.removeQuoteToken(
                (amount * pool.quoteTokenScale()),
                index
            );
        }
        uint256 withdrawnBalance = _roundToScale(
            withdrawnBalanceWAD,
            pool.quoteTokenScale()
        ) / pool.quoteTokenScale();
        _send(debtToken, withdrawnBalance);
    }

    /**
     * @notice Reclaims collateral from liquidated bucket
     * @param  pool         Address of the Ajana Pool.
     * @param  price        Price of the bucket to redeem.
     */
    function _removeCollateral(IERC20Pool pool, uint256 price)
        internal
        returns (uint256 withdrawnBalance)
    {
        address collateralToken = pool.collateralAddress();
        uint256 index = convertPriceToIndex(price);
        (uint256 withdrawnBalanceWAD, ) = pool.removeCollateral(
            type(uint256).max,
            index
        );
        withdrawnBalance =
            _roundToScale(withdrawnBalanceWAD, pool.collateralScale()) /
            pool.collateralScale();
        _send(collateralToken, withdrawnBalance);
    }

    // BORROWER ACTIONS

    /**
     *  @notice Deposit collateral
     *  @param  pool           Pool address
     *  @param  collateralAmount Amount of collateral to deposit
     *  @param  price          Price of the bucket
     *  @param stamploanEnabled      Whether to stamp the loan or not
     */
    function depositCollateral(
        IERC20Pool pool,
        uint256 collateralAmount,
        uint256 price,
        bool stamploanEnabled
    ) public payable {
        address collateralToken = pool.collateralAddress();
        _pull(collateralToken, collateralAmount);

        uint256 index = convertPriceToIndex(price);
        IERC20(collateralToken).approve(address(pool), collateralAmount);
        pool.drawDebt(
            address(this),
            0,
            index,
            collateralAmount * pool.collateralScale()
        );
        _stampLoan(pool, stamploanEnabled);
        emit ProxyActionsOperation("AjnaDeposit");
    }

    /**
     *  @notice Draw debt
     *  @param  pool           Pool address
     *  @param  debtAmount     Amount of debt to draw
     *  @param  price          Price of the bucket
     */
    function drawDebt(
        IERC20Pool pool,
        uint256 debtAmount,
        uint256 price
    ) public {
        address debtToken = pool.quoteTokenAddress();
        uint256 index = convertPriceToIndex(price);

        pool.drawDebt(
            address(this),
            debtAmount * pool.quoteTokenScale(),
            index,
            0
        );
        _send(debtToken, debtAmount);
        emit ProxyActionsOperation("AjnaBorrow");
    }

    /**
     *  @notice Deposit collateral and draw debt
     *  @param  pool           Pool address
     *  @param  debtAmount     Amount of debt to draw
     *  @param  collateralAmount Amount of collateral to deposit
     *  @param  price          Price of the bucket
     */
    function depositCollateralAndDrawDebt(
        IERC20Pool pool,
        uint256 debtAmount,
        uint256 collateralAmount,
        uint256 price
    ) public {
        address debtToken = pool.quoteTokenAddress();
        address collateralToken = pool.collateralAddress();
        uint256 index = convertPriceToIndex(price);
        _pull(collateralToken, collateralAmount);
        IERC20(collateralToken).approve(address(pool), collateralAmount);
        pool.drawDebt(
            address(this),
            debtAmount * pool.quoteTokenScale(),
            index,
            collateralAmount * pool.collateralScale()
        );
        _send(debtToken, debtAmount);
        emit ProxyActionsOperation("AjnaDepositBorrow");
    }

    /**
     *  @notice Deposit collateral and draw debt
     *  @param  pool           Pool address
     *  @param  debtAmount     Amount of debt to borrow
     *  @param  collateralAmount Amount of collateral to deposit
     *  @param  price          Price of the bucket
     *  @param stamploanEnabled      Whether to stamp the loan or not
     */
    function depositAndDraw(
        IERC20Pool pool,
        uint256 debtAmount,
        uint256 collateralAmount,
        uint256 price,
        bool stamploanEnabled
    ) public payable {
        if (debtAmount > 0 && collateralAmount > 0) {
            depositCollateralAndDrawDebt(
                pool,
                debtAmount,
                collateralAmount,
                price
            );
        } else if (debtAmount > 0) {
            drawDebt(pool, debtAmount, price);
        } else if (collateralAmount > 0) {
            depositCollateral(pool, collateralAmount, price, stamploanEnabled);
        }
    }

    /**
     *  @notice Repay debt
     *  @param  pool           Pool address
     *  @param  amount         Amount of debt to repay
     *  @param stamploanEnabled      Whether to stamp the loan or not
     */
    function repayDebt(
        IERC20Pool pool,
        uint256 amount,
        bool stamploanEnabled
    ) public payable {
        address debtToken = pool.quoteTokenAddress();
        _pull(debtToken, amount);
        IERC20(debtToken).approve(address(pool), amount);
        (, , , , , uint256 lupIndex_) = poolInfoUtils.poolPricesInfo(
            address(pool)
        );
        uint256 repaidAmountWAD = pool.repayDebt(
            address(this),
            amount * pool.quoteTokenScale(),
            0,
            address(this),
            lupIndex_
        );
        _stampLoan(pool, stamploanEnabled);
        uint256 repaidAmount = _roundUpToScale(
            repaidAmountWAD,
            pool.quoteTokenScale()
        ) / pool.quoteTokenScale();
        uint256 leftoverBalance = amount - repaidAmount;
        if (leftoverBalance > 0) {
            _send(debtToken, leftoverBalance);
        }
        IERC20(debtToken).safeApprove(address(pool), 0);
        emit ProxyActionsOperation("AjnaRepay");
    }

    /**
     *  @notice Withdraw collateral
     *  @param  pool           Pool address
     *  @param  amount         Amount of collateral to withdraw
     */
    function withdrawCollateral(IERC20Pool pool, uint256 amount) public {
        address collateralToken = pool.collateralAddress();
        (, , , , , uint256 lupIndex_) = poolInfoUtils.poolPricesInfo(
            address(pool)
        );
        pool.repayDebt(
            address(this),
            0,
            amount * pool.collateralScale(),
            address(this),
            lupIndex_
        );
        _send(collateralToken, amount);
        emit ProxyActionsOperation("AjnaWithdraw");
    }

    /**
     *  @notice Repay debt and withdraw collateral
     *  @param  pool           Pool address
     *  @param  debtAmount         Amount of debt to repay
     *  @param  collateralAmount         Amount of collateral to withdraw
     */
    function repayDebtAndWithdrawCollateral(
        IERC20Pool pool,
        uint256 debtAmount,
        uint256 collateralAmount
    ) public {
        address debtToken = pool.quoteTokenAddress();
        address collateralToken = pool.collateralAddress();
        _pull(debtToken, debtAmount);
        IERC20(debtToken).approve(address(pool), debtAmount);
        (, , , , , uint256 lupIndex_) = poolInfoUtils.poolPricesInfo(
            address(pool)
        );
        uint256 repaidAmountWAD = pool.repayDebt(
            address(this),
            debtAmount * pool.quoteTokenScale(),
            collateralAmount * pool.collateralScale(),
            address(this),
            lupIndex_
        );
        _send(collateralToken, collateralAmount);
        uint256 repaidAmount = _roundUpToScale(
            repaidAmountWAD,
            pool.quoteTokenScale()
        ) / pool.quoteTokenScale();
        uint256 quoteLeftoverBalance = debtAmount - repaidAmount;
        if (quoteLeftoverBalance > 0) {
            _send(debtToken, quoteLeftoverBalance);
        }
        IERC20(debtToken).safeApprove(address(pool), 0);
        emit ProxyActionsOperation("AjnaRepayWithdraw");
    }

    /**
     *  @notice Repay debt and withdraw collateral for msg.sender
     *  @param  pool           Pool address
     *  @param  debtAmount     Amount of debt to repay
     *  @param  collateralAmount Amount of collateral to withdraw
     *  @param stamploanEnabled      Whether to stamp the loan or not
     */
    function repayWithdraw(
        IERC20Pool pool,
        uint256 debtAmount,
        uint256 collateralAmount,
        bool stamploanEnabled
    ) external payable {
        if (debtAmount > 0 && collateralAmount > 0) {
            repayDebtAndWithdrawCollateral(pool, debtAmount, collateralAmount);
        } else if (debtAmount > 0) {
            repayDebt(pool, debtAmount, stamploanEnabled);
        } else if (collateralAmount > 0) {
            withdrawCollateral(pool, collateralAmount);
        }
    }

    /**
     *  @notice Repay debt and close position for msg.sender
     *  @param  pool           Pool address
     */
    function repayAndClose(IERC20Pool pool) public payable {
        address collateralToken = pool.collateralAddress();
        address debtToken = pool.quoteTokenAddress();

        (uint256 debt, uint256 collateral, ) = poolInfoUtils.borrowerInfo(
            address(pool),
            address(this)
        );
        uint256 debtPlusBuffer = _roundUpToScale(debt, pool.quoteTokenScale());
        uint256 amountDebt = debtPlusBuffer / pool.quoteTokenScale();
        _pull(debtToken, amountDebt);

        IERC20(debtToken).approve(address(pool), amountDebt);
        (, , , , , uint256 lupIndex_) = poolInfoUtils.poolPricesInfo(
            address(pool)
        );
        pool.repayDebt(
            address(this),
            debtPlusBuffer,
            collateral,
            address(this),
            lupIndex_
        );

        uint256 amountCollateral = collateral / pool.collateralScale();
        _send(collateralToken, amountCollateral);
        IERC20(debtToken).safeApprove(address(pool), 0);
        emit ProxyActionsOperation("AjnaRepayAndClose");
    }

    /**
     *  @notice Open position for msg.sender
     *  @param  pool           Pool address
     *  @param  debtAmount     Amount of debt to borrow
     *  @param  collateralAmount Amount of collateral to deposit
     *  @param  price          Price of the bucket
     */
    function openPosition(
        IERC20Pool pool,
        uint256 debtAmount,
        uint256 collateralAmount,
        uint256 price
    ) public payable {
        emit CreatePosition(
            address(this),
            ajnaVersion,
            "Borrow",
            pool.collateralAddress(),
            pool.quoteTokenAddress()
        );
        depositAndDraw(pool, debtAmount, collateralAmount, price, false);
    }

    /**
     *  @notice Open Earn position for msg.sender
     *  @param  pool           Pool address
     *  @param  depositAmount     Amount of debt to borrow
     *  @param  price          Price of the bucket
     */
    function openEarnPosition(
        IERC20Pool pool,
        uint256 depositAmount,
        uint256 price
    ) public payable {
        emit CreatePosition(
            address(this),
            ajnaVersion,
            "Earn",
            pool.collateralAddress(),
            pool.quoteTokenAddress()
        );
        _validateBucketState(pool, convertPriceToIndex(price));
        _supplyQuote(pool, depositAmount, price);
        emit ProxyActionsOperation("AjnaSupplyQuote");
    }

    /**
     *  @notice Called by lenders to add an amount of credit at a specified price bucket.
     *  @param  pool         Address of the Ajana Pool.
     *  @param  amount       The maximum amount of quote token to be moved by a lender.
     *  @param  price        The price the bucket to which the quote tokens will be added.

     *  @dev price of uint (10**decimals) collateral token in debt token (10**decimals) with 3 decimal points for instance
     *  @dev 1WBTC = 16,990.23 USDC   translates to: 16990230
     */
    function supplyQuote(
        IERC20Pool pool,
        uint256 amount,
        uint256 price
    ) public payable {
        _validateBucketState(pool, convertPriceToIndex(price));
        _supplyQuote(pool, amount, price);
        emit ProxyActionsOperation("AjnaSupplyQuote");
    }

    /**
     *  @notice Called by lenders to remove an amount of credit at a specified price bucket.
     *  @param  pool         Address of the Ajana Pool.
     *  @param  amount       The maximum amount of quote token to be moved by a lender.
     *  @param  price        The price the bucket to which the quote tokens will be added.
     *  @dev price of uint (10**decimals) collateral token in debt token (10**decimals) with 3 decimal points for instance
     *  @dev 1WBTC = 16,990.23 USDC   translates to: 16990230
     */
    function withdrawQuote(
        IERC20Pool pool,
        uint256 amount,
        uint256 price
    ) public {
        _withdrawQuote(pool, amount, price);
        emit ProxyActionsOperation("AjnaWithdrawQuote");
    }

    /**
     *  @notice Called by lenders to move max amount of credit from a specified price bucket to another specified price bucket.
     *  @param  pool         Address of the Ajana Pool.
     *  @param  oldPrice        The price of the bucket  from which the quote tokens will be removed.
     *  @param  newPrice     The price of the bucket to which the quote tokens will be added.

     */
    function moveQuote(
        IERC20Pool pool,
        uint256 oldPrice,
        uint256 newPrice
    ) public {
        _validateBucketState(pool, convertPriceToIndex(newPrice));
        _moveQuote(pool, oldPrice, newPrice);
        emit ProxyActionsOperation("AjnaMoveQuote");
    }

    /**
     *  @notice Called by lenders to move an amount of credit from a specified price bucket to another specified price bucket,
     *  @notice whilst adding additional amount.
     *  @param  pool            Address of the Ajana Pool.
     *  @param  amountToAdd     The maximum amount of quote token to be moved by a lender.
     *  @param  oldPrice        The price of the bucket  from which the quote tokens will be removed.
     *  @param  newPrice        The price of the bucket to which the quote tokens will be added.

     */
    function supplyAndMoveQuote(
        IERC20Pool pool,
        uint256 amountToAdd,
        uint256 oldPrice,
        uint256 newPrice
    ) public payable {
        uint256 newIndex = convertPriceToIndex(newPrice);
        _validateBucketState(pool, newIndex);
        _supplyQuote(pool, amountToAdd, newPrice);
        _validateBucketState(pool, newIndex);
        _moveQuote(pool, oldPrice, newPrice);
        emit ProxyActionsOperation("AjnaSupplyAndMoveQuote");
    }

    /**
     *  @notice Called by lenders to move an amount of credit from a specified price bucket to another specified price bucket,
     *  @notice whilst withdrawing additional amount.
     *  @param  pool            Address of the Ajana Pool.
     *  @param  amountToWithdraw     Amount of quote token to be withdrawn by a lender.
     *  @param  oldPrice        The price of the bucket  from which the quote tokens will be removed.
     *  @param  newPrice        The price of the bucket to which the quote tokens will be added.

     */
    function withdrawAndMoveQuote(
        IERC20Pool pool,
        uint256 amountToWithdraw,
        uint256 oldPrice,
        uint256 newPrice
    ) public {
        _withdrawQuote(pool, amountToWithdraw, oldPrice);
        _validateBucketState(pool, convertPriceToIndex(newPrice));
        _moveQuote(pool, oldPrice, newPrice);
        emit ProxyActionsOperation("AjnaWithdrawAndMoveQuote");
    }

    /**
     * @notice Reclaims collateral from liquidated bucket
     * @param  pool         Address of the Ajana Pool.
     * @param  price        Price of the bucket to redeem.
     */
    function removeCollateral(IERC20Pool pool, uint256 price) public {
        _removeCollateral(pool, price);
        emit ProxyActionsOperation("AjnaRemoveCollateral");
    }

    // VIEW FUNCTIONS
    /**
     * @notice  Converts price to index
     * @param   price   price of uint (10**decimals) collateral token in debt token (10**decimals) with 18 decimal points for instance
     * @return index   index of the bucket
     * @dev     price of uint (10**decimals) collateral token in debt token (10**decimals) with 18 decimal points for instance
     * @dev     1WBTC = 16,990.23 USDC   translates to: 16990230000000000000000
     */
    function convertPriceToIndex(uint256 price) public view returns (uint256) {
        return poolInfoUtils.priceToIndex(price);
    }

    /**
     * @dev Validates the state of a bucket in an IERC20Pool contract.
     * @param pool The IERC20Pool contract address.
     * @param bucket The index of the bucket to validate.
     */
    function _validateBucketState(IERC20Pool pool, uint256 bucket) public view {
        (, , , uint256 bucketLP_, , ) = poolInfoUtils.bucketInfo(
            address(pool),
            bucket
        );
        require(
            bucketLP_ == 0 || bucketLP_ > 1_000_000,
            "apa/bucket-lps-invalid"
        );
    }

    /**
     *  @notice Get the amount of quote token deposited to a specific bucket
     *  @param  pool         Address of the Ajana Pool.
     *  @param  price        Price of the bucket to query
     *  @return  quoteAmount Amount of quote token deposited to dpecific bucket
     *  @dev price of uint (10**decimals) collateral token in debt token (10**decimals) with 18 decimal points for instance
     *  @dev     1WBTC = 16,990.23 USDC   translates to: 16990230000000000000000
     */
    function getQuoteAmount(IERC20Pool pool, uint256 price)
        public
        view
        returns (uint256 quoteAmount)
    {
        uint256 index = convertPriceToIndex(price);

        (uint256 lpCount, ) = pool.lenderInfo(index, address(this));
        quoteAmount = poolInfoUtils.lpToQuoteTokens(
            address(pool),
            lpCount,
            index
        );
    }

    /**
     *  @notice Rounds a token amount down to the minimum amount permissible by the token scale.
     *  @param  amount_       Value to be rounded.
     *  @param  tokenScale_   Scale of the token, presented as a power of `10`.
     *  @return scaledAmount_ Rounded value.
     */
    function _roundToScale(uint256 amount_, uint256 tokenScale_)
        internal
        pure
        returns (uint256 scaledAmount_)
    {
        scaledAmount_ = (amount_ / tokenScale_) * tokenScale_;
    }

    /**
     *  @notice Rounds a token amount up to the next amount permissible by the token scale.
     *  @param  amount_       Value to be rounded.
     *  @param  tokenScale_   Scale of the token, presented as a power of `10`.
     *  @return scaledAmount_ Rounded value.
     */
    function _roundUpToScale(uint256 amount_, uint256 tokenScale_)
        internal
        pure
        returns (uint256 scaledAmount_)
    {
        if (amount_ % tokenScale_ == 0) scaledAmount_ = amount_;
        else scaledAmount_ = _roundToScale(amount_, tokenScale_) + tokenScale_;
    }
}
