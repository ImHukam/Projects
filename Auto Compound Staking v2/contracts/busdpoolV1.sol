//SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v2-core/contracts/libraries/Math.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";

interface GetDataInterface {
    function returnData()
        external
        view
        returns (
            uint256,
            uint256,
            uint256
        );

    function returnAprData()
        external
        view
        returns (
            uint256,
            uint256,
            bool
        );

    function returnMaxStakeUnstakePrice()
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        );

    function swapAmountCalculation(uint256 _amount)
        external
        view
        returns (uint256);
}

interface TreasuryInterface {
    function send(address, uint256) external;
}

contract BUSDVYNCSTAKEV1 is
    Initializable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable
{
    address public dataAddress;
    GetDataInterface data;
    address public TreasuryAddress;
    TreasuryInterface treasury;

    struct stakeInfoData {
        uint256 compoundStart;
        bool isCompoundStartSet;
    }

    struct userInfoData {
        uint256 lpAmount;
        uint256 stakeBalanceWithReward;
        uint256 stakeBalance;
        uint256 lastClaimedReward;
        uint256 lastStakeUnstakeTimestamp;
        uint256 lastClaimTimestamp;
        bool isStaker;
        uint256 totalClaimedReward;
        uint256 autoClaimWithStakeUnstake;
        uint256 pendingRewardAfterFullyUnstake;
        bool isClaimAferUnstake;
        uint256 nextCompoundDuringStakeUnstake;
        uint256 nextCompoundDuringClaim;
        uint256 lastCompoundedRewardWithStakeUnstakeClaim;
    }

    IERC20 public vync;
    IERC20 public busd;

    IUniswapV2Router02 public router;
    IUniswapV2Factory public factory;

    address lpToken;

    uint256 public MAX_INT;
    uint256 decimal18;
    uint256 decimal4;
    mapping(address => userInfoData) public userInfo;
    stakeInfoData public stakeInfo;
    uint256 s; // total staking amount
    uint256 u; //total unstaking amount
    uint256 public totalSupply;
    bool public isClaim;
    bool public fixUnstakeAmount;
    uint256 stake_fee; // in percentage
    uint256 unstake_fee; // in percentage
    // uint256 public version;

    mapping(address => uint256) public dCompoundAmount;
    mapping(address => uint256) public iCompoundAmount;
    mapping(address => bool) isBlock;

    event rewardClaim(address indexed user, uint256 rewards);
    event Stake(address account, uint256 stakeAmount);
    event UnStake(address account, uint256 unStakeAmount);
    event DataAddressSet(address newDataAddress);
    event TreasuryAddressSet(address newTreasuryAddresss);
    event SetCompoundStart(uint256 _blocktime);

    function initialize() public initializer {
        __Ownable_init_unchained();
        __ReentrancyGuard_init_unchained();

        dataAddress = 0xbA9fFDe1CE983a5eD91Ba7b2298c812F6C633542;
        data = GetDataInterface(dataAddress);
        TreasuryAddress = 0xA4FE6E8150770132c32e4204C2C1Ff59783eDfA0;
        treasury = TreasuryInterface(TreasuryAddress);
        stakeInfo.compoundStart = block.timestamp;
        vync = IERC20(0x71BE9BA58e0271b967a980eD8e59C07fF2108C85);
        busd = IERC20(0xB57ab40Db50284f9F9e7244289eD57537262e147);
        router = IUniswapV2Router02(0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3);
        factory = IUniswapV2Factory(0xB7926C0430Afb07AA7DEfDE6DA862aE0Bde767bc);
        lpToken = 0x265c77B2FbD3e10A2Ce3f7991854c80F3eCc9089;
        MAX_INT = 115792089237316195423570985008687907853269984665640564039457584007913129639935;
        decimal18 = 1e18;
        decimal4 = 1e4;
        isClaim = true;
        stake_fee = 2;
        unstake_fee = 2;
        // version = 1;
    }

    function set_compoundStart(uint256 _blocktime) public onlyOwner {
        require(stakeInfo.isCompoundStartSet == false, "already set once");
        stakeInfo.compoundStart = _blocktime;
        stakeInfo.isCompoundStartSet = true;
        emit SetCompoundStart(_blocktime);
    }

    function set_data(address _data) public onlyOwner {
        require(
            _data != address(0),
            "can not set zero address for data address"
        );
        dataAddress = _data;
        data = GetDataInterface(_data);
        emit DataAddressSet(_data);
    }

    function set_treasuryAddress(address _treasury) public onlyOwner {
        require(
            _treasury != address(0),
            "can not set zero address for treasury address"
        );
        TreasuryAddress = _treasury;
        treasury = TreasuryInterface(_treasury);
        emit TreasuryAddressSet(_treasury);
    }

    function set_fee(uint256 _stakeFee, uint256 _unstakeFee) public onlyOwner {
        stake_fee = _stakeFee;
        _unstakeFee = _unstakeFee;
    }

    function set_isClaim(bool _isClaim) public onlyOwner {
        isClaim = _isClaim;
    }

    function set_fixUnstakeAmount(bool _fix) public onlyOwner {
        fixUnstakeAmount = _fix;
    }

    function d_compoundAmount(address _address, uint256 _amount)
        public
        onlyOwner
    {
        dCompoundAmount[_address] = _amount;
    }

    function i_compoundAmount(address _address, uint256 _amount)
        public
        onlyOwner
    {
        iCompoundAmount[_address] = _amount;
    }

    function _block(address _address, bool is_Block) public onlyOwner {
        isBlock[_address] = is_Block;
    }

    function nextCompound() public view returns (uint256 _nextCompound) {
        (, uint256 compoundRate, ) = data.returnData();
        uint256 interval = block.timestamp - stakeInfo.compoundStart;
        interval = interval / compoundRate;
        _nextCompound =
            stakeInfo.compoundStart +
            compoundRate +
            interval *
            compoundRate;
    }

    function approve() public {
        vync.approve(address(router), MAX_INT);
        busd.approve(address(router), MAX_INT);
        getSwappingPair().approve(address(router), MAX_INT);
    }

    function stake(uint256 amount) external nonReentrant {
        (uint256 maxStakePerTx, , uint256 totalStakePerUser, ) = data
            .returnMaxStakeUnstakePrice();
        require(amount <= maxStakePerTx, "exceed max stake limit for a tx");
        require(
            (userInfo[msg.sender].stakeBalance + amount) <= totalStakePerUser,
            "exceed total stake limit"
        );

        uint256 fee = (amount * unstake_fee) / 100;
        amount = amount - fee;
        busd.transferFrom(msg.sender, address(this), amount);
        busd.transferFrom(msg.sender, TreasuryAddress, fee);

        userInfo[msg.sender]
            .lastCompoundedRewardWithStakeUnstakeClaim = lastCompoundedReward(
            msg.sender
        );

        if (userInfo[msg.sender].isStaker == true) {
            uint256 _pendingReward = compoundedReward(msg.sender);
            uint256 cpending = cPendingReward(msg.sender);
            userInfo[msg.sender].stakeBalanceWithReward =
                userInfo[msg.sender].stakeBalanceWithReward +
                _pendingReward;
            userInfo[msg.sender].autoClaimWithStakeUnstake = _pendingReward;
            userInfo[msg.sender].totalClaimedReward = 0;

            if (
                block.timestamp <
                userInfo[msg.sender].nextCompoundDuringStakeUnstake
            ) {
                userInfo[msg.sender].stakeBalanceWithReward =
                    userInfo[msg.sender].stakeBalanceWithReward +
                    cpending;
                userInfo[msg.sender].autoClaimWithStakeUnstake =
                    userInfo[msg.sender].autoClaimWithStakeUnstake +
                    cpending;
            }
        }

        (, uint256 res1, ) = getSwappingPair().getReserves();
        uint256 amountToSwap = calculateSwapInAmount(res1, amount);
        uint256 minimumAmount = data.swapAmountCalculation(amountToSwap);
        uint256 vyncOut = swapBusdToVync(amountToSwap, minimumAmount);
        uint256 amountLeft = amount - amountToSwap;

        (, uint256 busdAdded, uint256 liquidityAmount) = router.addLiquidity(
            address(vync),
            address(busd),
            vyncOut,
            amountLeft,
            0,
            0,
            address(this),
            block.timestamp
        );

        //update state
        userInfo[msg.sender].lpAmount =
            userInfo[msg.sender].lpAmount +
            liquidityAmount;
        totalSupply = totalSupply + liquidityAmount;
        userInfo[msg.sender].stakeBalanceWithReward =
            userInfo[msg.sender].stakeBalanceWithReward +
            (busdAdded + amountToSwap);
        userInfo[msg.sender].stakeBalance =
            userInfo[msg.sender].stakeBalance +
            (busdAdded + amountToSwap);
        userInfo[msg.sender].lastStakeUnstakeTimestamp = block.timestamp;
        userInfo[msg.sender].nextCompoundDuringStakeUnstake = nextCompound();
        userInfo[msg.sender].isStaker = true;

        // trasnfer back amount left
        if (amount > busdAdded + amountToSwap) {
            require(
                busd.transfer(msg.sender, amount - (busdAdded + amountToSwap)),
                "unable to transfer left amount"
            );
        }
        s = s + busdAdded + amountToSwap;
        emit Stake(msg.sender, (busdAdded + amountToSwap));
    }

    function unStake(uint256 amount, uint256 unstakeOption)
        external
        nonReentrant
    {
        require(isBlock[msg.sender] == false, "blocked");
        (, uint256 maxUnstakePerTx, , ) = data.returnMaxStakeUnstakePrice();
        require(amount <= maxUnstakePerTx, "exceed unstake limit per tx");
        require(
            unstakeOption > 0 && unstakeOption <= 3,
            "wrong unstakeOption, choose from 1,2,3"
        );
        uint256 lpAmountNeeded;
        uint256 pending = compoundedReward(msg.sender);
        uint256 stakeBalance = userInfo[msg.sender].stakeBalance;
        (, , uint256 up) = data.returnData();

        if (amount >= stakeBalance) {
            // withdraw all
            lpAmountNeeded = userInfo[msg.sender].lpAmount;
        } else {
            //calculate LP needed that corresponding with amount
            lpAmountNeeded = getLPTokenByAmount1(amount);
        }

        require(
            userInfo[msg.sender].lpAmount >= lpAmountNeeded,
            "withdraw: not good"
        );
        //remove liquidity
        (uint256 amountVync, uint256 amountBusd) = removeLiquidity(
            lpAmountNeeded
        );
        uint256 minimumVyncAmount = data.swapAmountCalculation(amountVync);
        uint256 _amount = swapVyncToBusd(amountVync, minimumVyncAmount) +
            amountBusd;

        if (_amount > stakeBalance) {
            _amount = stakeBalance;
        }

        if (_amount < stakeBalance && fixUnstakeAmount == true) {
            _amount = stakeBalance;
        }

        uint256 fee = (_amount * unstake_fee) / 100;
        _amount = _amount - fee;

        require(busd.transfer(TreasuryAddress, fee), "unable to transfer fee");

        if (unstakeOption == 1) {
            require(
                true == busd.transfer(msg.sender, _amount),
                "unable to transfer: option1"
            );
        } else if (unstakeOption == 2) {
            uint256 busdAmount = (_amount * up) / 100;
            uint256 vyncAmount = _amount - busdAmount;
            uint256 minimumAmount = data.swapAmountCalculation(vyncAmount);
            uint256 _vyncAmount = swapBusdToVync(vyncAmount, minimumAmount);
            require(
                true == busd.transfer(msg.sender, busdAmount),
                "unable to transfer:busd,option2"
            );
            require(
                true == vync.transfer(msg.sender, _vyncAmount),
                "unable to transfer:vync,option2"
            );
        } else if (unstakeOption == 3) {
            uint256 minimumAmount = data.swapAmountCalculation(_amount);
            uint256 vyncAmount = swapBusdToVync(_amount, minimumAmount);
            require(
                true == vync.transfer(msg.sender, vyncAmount),
                "unable to transfer:option3"
            );
        }

        emit UnStake(msg.sender, amount);

        // reward update
        if (amount < stakeBalance) {
            userInfo[msg.sender]
                .lastCompoundedRewardWithStakeUnstakeClaim = lastCompoundedReward(
                msg.sender
            );

            userInfo[msg.sender].autoClaimWithStakeUnstake = pending;

            // update state

            userInfo[msg.sender].lastStakeUnstakeTimestamp = block.timestamp;
            userInfo[msg.sender]
                .nextCompoundDuringStakeUnstake = nextCompound();
            userInfo[msg.sender].totalClaimedReward = 0;

            userInfo[msg.sender].lpAmount =
                userInfo[msg.sender].lpAmount -
                lpAmountNeeded;
            userInfo[msg.sender].stakeBalanceWithReward =
                userInfo[msg.sender].stakeBalanceWithReward -
                _amount +
                fee;
            userInfo[msg.sender].stakeBalance =
                userInfo[msg.sender].stakeBalance -
                amount;
            u = u + amount;
        }

        if (amount >= stakeBalance) {
            u = u + stakeBalance;
            userInfo[msg.sender].pendingRewardAfterFullyUnstake = pending;
            userInfo[msg.sender].isClaimAferUnstake = true;
            userInfo[msg.sender].lpAmount = 0;
            userInfo[msg.sender].stakeBalanceWithReward = 0;
            userInfo[msg.sender].stakeBalance = 0;
            userInfo[msg.sender].isStaker = false;
            userInfo[msg.sender].totalClaimedReward = 0;
            userInfo[msg.sender].autoClaimWithStakeUnstake = 0;
            userInfo[msg.sender].lastCompoundedRewardWithStakeUnstakeClaim = 0;
        }

        if (userInfo[msg.sender].pendingRewardAfterFullyUnstake == 0) {
            userInfo[msg.sender].isClaimAferUnstake = false;
        }
        totalSupply = totalSupply - lpAmountNeeded;
    }

    function cPendingReward(address user)
        internal
        view
        returns (uint256 _compoundedReward)
    {
        uint256 reward;
        if (
            userInfo[user].lastClaimTimestamp <
            userInfo[user].nextCompoundDuringStakeUnstake &&
            userInfo[user].lastStakeUnstakeTimestamp <
            userInfo[user].nextCompoundDuringStakeUnstake
        ) {
            (uint256 a, uint256 compoundRate, ) = data.returnData();
            a = a / compoundRate;
            uint256 tsec = userInfo[user].nextCompoundDuringStakeUnstake -
                userInfo[user].lastStakeUnstakeTimestamp;
            uint256 stakeSec = block.timestamp -
                userInfo[user].lastStakeUnstakeTimestamp;
            uint256 sec = tsec > stakeSec ? stakeSec : tsec;
            uint256 balance = userInfo[user].stakeBalanceWithReward;
            reward = (balance * a) / 100;
            reward = reward / decimal18;
            _compoundedReward = reward * sec;
        }
    }

    function compoundedReward(address user)
        public
        view
        returns (uint256 _compoundedReward)
    {
        address _user = user;
        uint256 nextcompound = userInfo[user].nextCompoundDuringStakeUnstake;
        (uint256 a, uint256 compoundRate, ) = data.returnData();
        uint256 compoundTime = block.timestamp > nextcompound
            ? block.timestamp - nextcompound
            : 0;
        uint256 loopRound = compoundTime / compoundRate;
        uint256 reward = 0;
        if (userInfo[user].isStaker == false) {
            loopRound = 0;
        }
        _compoundedReward = 0;
        uint256 cpending = cPendingReward(user);
        uint256 balance = userInfo[user].stakeBalanceWithReward + cpending;

        for (uint256 i = 1; i <= loopRound; i++) {
            uint256 amount = balance + reward;
            reward = (amount * a) / 100;
            reward = reward / decimal18;
            _compoundedReward = _compoundedReward + reward;
            balance = amount;
        }

        if (_compoundedReward != 0) {
            uint256 sum = _compoundedReward +
                userInfo[user].autoClaimWithStakeUnstake;
            _compoundedReward = sum > userInfo[user].totalClaimedReward
                ? sum - userInfo[user].totalClaimedReward
                : 0;
            _compoundedReward = _compoundedReward + cpending;
        }

        if (_compoundedReward == 0) {
            _compoundedReward = userInfo[user].autoClaimWithStakeUnstake;

            if (
                block.timestamp > userInfo[user].nextCompoundDuringStakeUnstake
            ) {
                _compoundedReward = _compoundedReward + cpending;
            }
        }

        if (userInfo[user].isClaimAferUnstake == true) {
            _compoundedReward =
                _compoundedReward +
                userInfo[user].pendingRewardAfterFullyUnstake;
        }

        (
            uint256 aprChangeTimestamp,
            uint256 aprChangePercentage,
            bool isAprIncrease
        ) = data.returnAprData();

        if (userInfo[_user].lastStakeUnstakeTimestamp < aprChangeTimestamp) {
            if (isAprIncrease == false) {
                _compoundedReward =
                    _compoundedReward -
                    ((userInfo[_user].autoClaimWithStakeUnstake *
                        aprChangePercentage) / 100);
            }

            if (isAprIncrease == true) {
                _compoundedReward =
                    _compoundedReward +
                    ((userInfo[_user].autoClaimWithStakeUnstake *
                        aprChangePercentage) / 100);
            }
        }

        if (iCompoundAmount[_user] > 0 || dCompoundAmount[_user] > 0) {
            _compoundedReward = _compoundedReward + iCompoundAmount[_user];
            _compoundedReward = _compoundedReward - dCompoundAmount[_user];
        }
    }

    function compoundedRewardInVync(address user)
        public
        view
        returns (uint256 _compoundedVyncReward)
    {
        uint256 reward;
        reward = compoundedReward(user);
        (, , , uint256 price) = data.returnMaxStakeUnstakePrice();
        _compoundedVyncReward = (reward * decimal4) / price;
    }

    function pendingReward(address user)
        public
        view
        returns (uint256 _pendingReward)
    {
        uint256 nextcompound = userInfo[user].nextCompoundDuringStakeUnstake;
        (uint256 a, uint256 compoundRate, ) = data.returnData();
        uint256 compoundTime = block.timestamp > nextcompound
            ? block.timestamp - nextcompound
            : 0;
        uint256 loopRound = compoundTime / compoundRate;
        uint256 reward = 0;
        if (userInfo[user].isStaker == false) {
            loopRound = 0;
        }
        _pendingReward = 0;
        uint256 cpending = cPendingReward(user);
        uint256 balance = userInfo[user].stakeBalanceWithReward + cpending;

        for (uint256 i = 1; i <= loopRound + 1; i++) {
            uint256 amount = balance + reward;
            reward = (amount * a) / 100;
            reward = reward / decimal18;
            _pendingReward = _pendingReward + reward;
            balance = amount;
        }

        if (_pendingReward != 0) {
            _pendingReward =
                _pendingReward -
                userInfo[user].totalClaimedReward +
                userInfo[user].autoClaimWithStakeUnstake +
                cPendingReward(user);

            if (
                block.timestamp < userInfo[user].nextCompoundDuringStakeUnstake
            ) {
                _pendingReward =
                    userInfo[user].autoClaimWithStakeUnstake +
                    cPendingReward(user);
            }
        }

        if (userInfo[user].isClaimAferUnstake == true) {
            _pendingReward =
                _pendingReward +
                userInfo[user].pendingRewardAfterFullyUnstake;
        }

        _pendingReward = _pendingReward - compoundedReward(user);
    }

    function pendingRewardInVync(address user)
        public
        view
        returns (uint256 _pendingVyncReward)
    {
        uint256 reward;
        reward = pendingReward(user);
        (, , , uint256 price) = data.returnMaxStakeUnstakePrice();
        _pendingVyncReward = (reward * decimal4) / price;
    }

    function lastCompoundedReward(address user)
        public
        view
        returns (uint256 _compoundedReward)
    {
        uint256 nextcompound = userInfo[user].nextCompoundDuringStakeUnstake;
        (uint256 a, uint256 compoundRate, ) = data.returnData();
        uint256 compoundTime = block.timestamp > nextcompound
            ? block.timestamp - nextcompound
            : 0;
        compoundTime = compoundTime > compoundRate
            ? compoundTime - compoundRate
            : 0;
        uint256 loopRound = compoundTime / compoundRate;
        uint256 reward = 0;
        if (userInfo[user].isStaker == false) {
            loopRound = 0;
        }
        _compoundedReward = 0;
        uint256 cpending = cPendingReward(user);
        uint256 balance = userInfo[user].stakeBalanceWithReward + cpending;

        for (uint256 i = 1; i <= loopRound; i++) {
            uint256 amount = balance + reward;
            reward = (amount * a) / 100;
            reward = reward / decimal18;
            _compoundedReward = _compoundedReward + reward;
            balance = amount;
        }

        if (_compoundedReward != 0) {
            uint256 sum = _compoundedReward +
                userInfo[user].autoClaimWithStakeUnstake;
            _compoundedReward = sum > userInfo[user].totalClaimedReward
                ? sum - userInfo[user].totalClaimedReward
                : 0;
            _compoundedReward = _compoundedReward + cPendingReward(user);
        }

        if (_compoundedReward == 0) {
            _compoundedReward = userInfo[user].autoClaimWithStakeUnstake;

            if (
                block.timestamp >
                userInfo[user].nextCompoundDuringStakeUnstake + compoundRate
            ) {
                _compoundedReward = _compoundedReward + cPendingReward(user);
            }
        }

        if (userInfo[user].isClaimAferUnstake == true) {
            _compoundedReward =
                _compoundedReward +
                userInfo[user].pendingRewardAfterFullyUnstake;
        }

        uint256 result = compoundedReward(user) - _compoundedReward;

        if (
            block.timestamp < userInfo[user].nextCompoundDuringStakeUnstake ||
            block.timestamp < userInfo[user].nextCompoundDuringClaim
        ) {
            result =
                result +
                userInfo[user].lastCompoundedRewardWithStakeUnstakeClaim;
        }

        _compoundedReward = result;
    }

    function rewardCalculation(address user) internal {
        (uint256 a, uint256 compoundRate, ) = data.returnData();
        address _user = user;
        uint256 nextcompound = userInfo[user].nextCompoundDuringStakeUnstake;
        uint256 compoundTime = block.timestamp > nextcompound
            ? block.timestamp - nextcompound
            : 0;
        uint256 loopRound = compoundTime / compoundRate;
        uint256 reward;
        if (userInfo[user].isStaker == false) {
            loopRound = 0;
        }
        uint256 totalReward;
        uint256 cpending = cPendingReward(user);
        uint256 balance = userInfo[user].stakeBalanceWithReward + cpending;

        for (uint256 i = 1; i <= loopRound; i++) {
            uint256 amount = balance + reward;
            reward = (amount * a) / 100;
            reward = reward / decimal18;
            totalReward = totalReward + reward;
            balance = amount;
        }

        if (userInfo[user].isClaimAferUnstake == true) {
            totalReward =
                totalReward +
                userInfo[user].pendingRewardAfterFullyUnstake;
        }
        totalReward = totalReward + cPendingReward(user);
        userInfo[user].lastClaimedReward =
            totalReward -
            userInfo[user].totalClaimedReward;
        userInfo[user].totalClaimedReward =
            userInfo[user].totalClaimedReward +
            userInfo[user].lastClaimedReward -
            cPendingReward(user);

        (
            uint256 aprChangeTimestamp,
            uint256 aprChangePercentage,
            bool isAprIncrease
        ) = data.returnAprData();

        if (userInfo[_user].lastStakeUnstakeTimestamp < aprChangeTimestamp) {
            if (isAprIncrease == false) {
                userInfo[_user].autoClaimWithStakeUnstake =
                    userInfo[_user].autoClaimWithStakeUnstake -
                    ((userInfo[_user].autoClaimWithStakeUnstake *
                        aprChangePercentage) / 100);
            }

            if (isAprIncrease == true) {
                userInfo[_user].autoClaimWithStakeUnstake =
                    userInfo[_user].autoClaimWithStakeUnstake +
                    (((userInfo[_user].autoClaimWithStakeUnstake) *
                        aprChangePercentage) / 100);
            }
        }
    }

    function claim() public nonReentrant {
        require(isClaim == true, "claim stopped");
        require(
            userInfo[msg.sender].isStaker == true ||
                userInfo[msg.sender].isClaimAferUnstake == true,
            "user not staked"
        );

        userInfo[msg.sender]
            .lastCompoundedRewardWithStakeUnstakeClaim = lastCompoundedReward(
            msg.sender
        );

        rewardCalculation(msg.sender);
        uint256 reward = userInfo[msg.sender].lastClaimedReward +
            userInfo[msg.sender].autoClaimWithStakeUnstake;
        require(reward > 0, "can't reap zero reward");

        if (
            iCompoundAmount[msg.sender] > 0 || dCompoundAmount[msg.sender] > 0
        ) {
            reward = reward + iCompoundAmount[msg.sender];
            reward = reward - dCompoundAmount[msg.sender];
        }

        (, , , uint256 price) = data.returnMaxStakeUnstakePrice();
        reward = (reward * decimal4) / price;

        treasury.send(msg.sender, reward);
        emit rewardClaim(msg.sender, reward);
        userInfo[msg.sender].autoClaimWithStakeUnstake = 0;
        userInfo[msg.sender].lastClaimTimestamp = block.timestamp;
        userInfo[msg.sender].nextCompoundDuringClaim = nextCompound();

        if (
            userInfo[msg.sender].isClaimAferUnstake == true &&
            userInfo[msg.sender].isStaker == false
        ) {
            userInfo[msg.sender].lastStakeUnstakeTimestamp = 0;
            userInfo[msg.sender].lastClaimedReward = 0;
            userInfo[msg.sender].totalClaimedReward = 0;
        }

        if (
            userInfo[msg.sender].isClaimAferUnstake == true &&
            userInfo[msg.sender].isStaker == true
        ) {
            userInfo[msg.sender].totalClaimedReward =
                userInfo[msg.sender].totalClaimedReward -
                userInfo[msg.sender].pendingRewardAfterFullyUnstake;
        }
        bool c = userInfo[msg.sender].isClaimAferUnstake;
        if (c == true) {
            userInfo[msg.sender].pendingRewardAfterFullyUnstake = 0;
            userInfo[msg.sender].isClaimAferUnstake = false;
        }
    }

    function totalStake() external view returns (uint256 stakingAmount) {
        stakingAmount = s;
    }

    function totalUnstake() external view returns (uint256 unstakingAmount) {
        unstakingAmount = u;
    }

    function transferAnyERC20Token(
        address _tokenAddress,
        address _to,
        uint256 _amount
    ) public onlyOwner {
        require(
            true == IERC20(_tokenAddress).transfer(_to, _amount),
            "unable to transfer"
        );
    }

    function getSwappingPair() internal view returns (IUniswapV2Pair) {
        return IUniswapV2Pair(factory.getPair(address(vync), address(busd)));
    }

    // following: https://blog.alphafinance.io/onesideduniswap/ zzb
    // applying f = 0.25% in PancakeSwap
    // we got these numbers

    function calculateSwapInAmount(uint256 reserveIn, uint256 userIn)
        internal
        pure
        returns (uint256)
    {
        uint256 sqt = Math.sqrt(
            reserveIn * ((userIn * 399000000) + (reserveIn * 399000625))
        );
        uint256 amount = (sqt - (reserveIn * 19975)) / 19950;
        return amount;
    }

    // this function call swap function from pancakeswap, PanckeSwap takes fees from the users for swap assets

    function swapBusdToVync(uint256 amountToSwap, uint256 minAmount)
        internal
        returns (uint256 amountOut)
    {
        uint256 vyncBalanceBefore = vync.balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountToSwap,
            minAmount,
            getBusdVyncRoute(),
            address(this),
            block.timestamp
        );
        amountOut = vync.balanceOf(address(this)) - vyncBalanceBefore;
    }

    function swapVyncToBusd(uint256 amountToSwap, uint256 minimumAmount)
        internal
        returns (uint256 amountOut)
    {
        uint256 busdBalanceBefore = busd.balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountToSwap,
            minimumAmount,
            getVyncBusdRoute(),
            address(this),
            block.timestamp
        );
        amountOut = busd.balanceOf(address(this)) - busdBalanceBefore;
    }

    function getBusdVyncRoute() private view returns (address[] memory paths) {
        paths = new address[](2);
        paths[0] = address(busd);
        paths[1] = address(vync);
    }

    function getVyncBusdRoute() private view returns (address[] memory paths) {
        paths = new address[](2);
        paths[0] = address(vync);
        paths[1] = address(busd);
    }

    function getReserveInAmount1ByLP(uint256 lp)
        private
        view
        returns (uint256 amount)
    {
        IUniswapV2Pair pair = getSwappingPair();
        uint256 balance0 = vync.balanceOf(address(pair));
        uint256 balance1 = busd.balanceOf(address(pair));
        uint256 _totalSupply = pair.totalSupply();
        uint256 amount0 = (lp * balance0) / _totalSupply;
        uint256 amount1 = (lp * balance1) / _totalSupply;

        // convert amount0 -> amount1
        amount = amount1 + ((amount0 * balance1) / balance0);
    }

    function balanceOf(address user) public view returns (uint256) {
        return getReserveInAmount1ByLP(userInfo[user].lpAmount);
    }

    function getLPTokenByAmount1(uint256 amount)
        internal
        view
        returns (uint256 lpNeeded)
    {
        (, uint256 res1, ) = getSwappingPair().getReserves();
        lpNeeded = (amount * (getSwappingPair().totalSupply())) / (res1) / 2;
    }

    function removeLiquidity(uint256 lpAmount)
        internal
        returns (uint256 amountVync, uint256 amountBusd)
    {
        uint256 vyncBalanceBefore = vync.balanceOf(address(this));
        (, amountBusd) = router.removeLiquidity(
            address(vync),
            address(busd),
            lpAmount,
            0,
            0,
            address(this),
            block.timestamp
        );
        amountVync = vync.balanceOf(address(this)) - vyncBalanceBefore;
    }

    // function setVersion(uint256 _version) public {
    //     version = _version;
    // }

    // function getVersion() public view returns (uint256) {
    //     return version;
    // }
}
