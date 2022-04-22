// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface GetDataInterface {
    function returnData()
        external
        view
        returns (
            uint256,
            uint256,
            uint256
        );
}

contract BUSDVYNCSTAKE is ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    address public dataAddress = 0x994Bde430BA69b96Ce14824c7d848c996A09Ba67;
    GetDataInterface data = GetDataInterface(dataAddress);

    uint256 s; // total staking amount
    uint256 u; //total unstaking amount

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
    }

    IERC20 public vync = IERC20(0x71BE9BA58e0271b967a980eD8e59C07fF2108C85);
    IERC20 public busd = IERC20(0xB57ab40Db50284f9F9e7244289eD57537262e147);
    address lpToken = 0x265c77B2FbD3e10A2Ce3f7991854c80F3eCc9089;

    IUniswapV2Router02 public router =
        IUniswapV2Router02(0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3);
    IUniswapV2Factory public factory =
        IUniswapV2Factory(0xB7926C0430Afb07AA7DEfDE6DA862aE0Bde767bc);

    uint256 public constant MAX_INT =
        115792089237316195423570985008687907853269984665640564039457584007913129639935;

    mapping(address => userInfoData) public userInfo;

    uint256 public totalSupply;

    event rewardClaim(address indexed user, uint256 rewards);
    event Stake(address account, uint256 stakeAmount);
    event UnStake(address account, uint256 unStakeAmount);

    function approve() public {
        vync.approve(address(router), MAX_INT);
        busd.approve(address(router), MAX_INT);
        getSwappingPair().approve(address(router), MAX_INT);
    }

    function set_data(address _data) public onlyOwner{
        dataAddress = _data;
        data = GetDataInterface(_data);
    }

    function stake(uint256 amount) external nonReentrant {
        busd.transferFrom(msg.sender, address(this), amount);

        if (userInfo[msg.sender].isStaker == true) {
            uint256 _pendingReward = compoundedReward(msg.sender);
            userInfo[msg.sender].stakeBalanceWithReward =
                userInfo[msg.sender].stakeBalanceWithReward +
                _pendingReward;
            userInfo[msg.sender].autoClaimWithStakeUnstake =
                userInfo[msg.sender].autoClaimWithStakeUnstake +
                _pendingReward;
            userInfo[msg.sender].totalClaimedReward = 0;
        }

        (, uint256 res1, ) = getSwappingPair().getReserves();
        uint256 amountToSwap = calculateSwapInAmount(res1, amount);

        uint256 vyncOut = swapBusdToVync(amountToSwap);
        uint256 amountLeft = amount.sub(amountToSwap);

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
        userInfo[msg.sender].lpAmount = userInfo[msg.sender].lpAmount.add(
            liquidityAmount
        );
        totalSupply = totalSupply.add(liquidityAmount);
        userInfo[msg.sender].stakeBalanceWithReward =
            userInfo[msg.sender].stakeBalanceWithReward +
            (busdAdded + amountToSwap);
        userInfo[msg.sender].stakeBalance =
            userInfo[msg.sender].stakeBalance +
            (busdAdded + amountToSwap);
        userInfo[msg.sender].lastStakeUnstakeTimestamp = block.timestamp;
        userInfo[msg.sender].isStaker = true;

        // trasnfer back amount left
        if (amount > busdAdded + amountToSwap) {
            busd.transfer(msg.sender, amount - (busdAdded + amountToSwap));
        }
        s = s + busdAdded + amountToSwap;
        emit Stake(msg.sender, (busdAdded + amountToSwap));
    }

    function unStake(uint256 amount, uint256 unstakeOption)
        external
        nonReentrant
    {
        require(
            unstakeOption > 0 && unstakeOption <= 3,
            "wrong unstakeOption, choose from 1,2,3"
        );
        uint256 lpAmountNeeded;
        uint256 pending = compoundedReward(msg.sender);
        uint256 stakeBalance = userInfo[msg.sender].stakeBalance;
        (,, uint256 up)=data.returnData();

        if (amount >= stakeBalance) {
            // withdraw all
            lpAmountNeeded = userInfo[msg.sender].lpAmount;
        } else {
            //calculate LP needed that corresponding with amount
            lpAmountNeeded = getLPTokenByAmount1(amount);
            if (lpAmountNeeded >= userInfo[msg.sender].lpAmount) {
                // if >= current lp, use all lp
                lpAmountNeeded = userInfo[msg.sender].lpAmount;
            }
        }

        require(
            userInfo[msg.sender].lpAmount >= lpAmountNeeded,
            "withdraw: not good"
        );
        //remove liquidity
        (uint256 amountVync, uint256 amountBusd) = removeLiquidity(
            lpAmountNeeded
        );

        uint256 _amount = swapVyncToBusd(amountVync).add(amountBusd);

        if (unstakeOption == 1) {
            busd.transfer(msg.sender, _amount);
        } else if (unstakeOption == 2) {
            uint256 busdAmount = (_amount * up) / 100;
            uint256 vyncAmount = _amount - busdAmount;

            uint256 _vyncAmount = swapBusdToVync(vyncAmount);
            busd.transfer(msg.sender, busdAmount);
            vync.transfer(msg.sender, _vyncAmount);
        } else if (unstakeOption == 3) {
            uint256 vyncAmount = swapBusdToVync(_amount);
            vync.transfer(msg.sender, vyncAmount);
        }

        emit UnStake(msg.sender, amount);

        // reward update
        if (amount < stakeBalance) {
            uint256 _pendingReward = compoundedReward(msg.sender);

            userInfo[msg.sender].autoClaimWithStakeUnstake = _pendingReward;

            // update state

            userInfo[msg.sender].lastStakeUnstakeTimestamp = block.timestamp;
            userInfo[msg.sender].totalClaimedReward = 0;

            userInfo[msg.sender].lpAmount = userInfo[msg.sender].lpAmount.sub(
                lpAmountNeeded
            );
            userInfo[msg.sender].stakeBalanceWithReward = userInfo[msg.sender]
                .stakeBalanceWithReward
                .sub(_amount);
            userInfo[msg.sender].stakeBalance = userInfo[msg.sender]
                .stakeBalance
                .sub(amount);
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
        }

        if (userInfo[msg.sender].pendingRewardAfterFullyUnstake == 0) {
            userInfo[msg.sender].isClaimAferUnstake = false;
        }

        totalSupply = totalSupply.sub(lpAmountNeeded);
    }

    function compoundedReward(address user)
        public
        view
        returns (uint256 _compoundedReward)
    {
        (,uint256 compoundRate,) = data.returnData();
        uint256 compoundTime = block.timestamp -
            userInfo[user].lastStakeUnstakeTimestamp;
        uint256 loopRound = compoundTime / compoundRate;
        uint256 reward = 0;
        if (userInfo[user].isStaker == false) {
            loopRound = 0;
        }
        (uint256 a,,) = data.returnData();
        _compoundedReward = 0;
        uint256 balance = userInfo[user].stakeBalanceWithReward;

        for (uint256 i = 1; i <= loopRound; i++) {
            uint256 amount = balance.add(reward);
            reward = (amount.mul(a)).div(100);
            reward = reward / 1e18;
            _compoundedReward = _compoundedReward.add(reward);
            balance = amount;
        }

        if (_compoundedReward != 0) {
            _compoundedReward =
                _compoundedReward -
                userInfo[user].totalClaimedReward +
                userInfo[user].autoClaimWithStakeUnstake;
        }

        if (_compoundedReward == 0) {
            _compoundedReward = userInfo[user].autoClaimWithStakeUnstake;
        }

        if (userInfo[user].isClaimAferUnstake == true) {
            _compoundedReward =
                _compoundedReward +
                userInfo[user].pendingRewardAfterFullyUnstake;
        }
    }

    function compoundedRewardInVync(address user)
        public
        view
        returns (uint256 _compoundedVyncReward)
    {
        uint256 reward;
        reward = compoundedReward(user);
        reward = reward * vyncPerBusd();
        _compoundedVyncReward = reward / 1e18;
    }

    function pendingReward(address user)
        public
        view
        returns (uint256 _pendingReward)
    {
        (,uint256 compoundRate,) = data.returnData();
        uint256 compoundTime = block.timestamp -
            userInfo[user].lastStakeUnstakeTimestamp;
        uint256 loopRound = compoundTime / compoundRate;
        uint256 reward = 0;
        (uint256 a,,) = data.returnData();
        if (userInfo[user].isStaker == false) {
            loopRound = 0;
        }
        _pendingReward = 0;
        uint256 balance = userInfo[user].stakeBalanceWithReward;

        for (uint256 i = 1; i <= loopRound + 1; i++) {
            uint256 amount = balance.add(reward);
            reward = (amount.mul(a)).div(100);
            reward = reward / 1e18;
            _pendingReward = _pendingReward.add(reward);
            balance = amount;
        }

        if (_pendingReward != 0) {
            _pendingReward =
                _pendingReward -
                userInfo[user].totalClaimedReward +
                userInfo[user].autoClaimWithStakeUnstake;
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
        reward = reward * vyncPerBusd();
        _pendingVyncReward = reward / 1e18;
    }

    function rewardCalculation(address user) internal {
        (,uint256 compoundRate,) = data.returnData();
        uint256 compoundTime = block.timestamp -
            userInfo[user].lastStakeUnstakeTimestamp;
        uint256 loopRound = compoundTime / compoundRate;
        (uint256 a,,)= data.returnData();
        uint256 reward;
        if (userInfo[user].isStaker == false) {
            loopRound = 0;
        }
        uint256 totalReward;
        uint256 balance = userInfo[user].stakeBalanceWithReward;

        for (uint256 i = 1; i <= loopRound; i++) {
            uint256 amount = balance.add(reward);
            reward = (amount.mul(a)).div(100);
            reward = reward / 1e18;
            totalReward = totalReward.add(reward);
            balance = amount;
        }

        if (userInfo[user].isClaimAferUnstake == true) {
            totalReward =
                totalReward +
                userInfo[user].pendingRewardAfterFullyUnstake;
        }
        userInfo[user].lastClaimedReward =
            totalReward -
            userInfo[user].totalClaimedReward;
        userInfo[user].totalClaimedReward =
            userInfo[user].totalClaimedReward +
            userInfo[user].lastClaimedReward;
    }

    function claim() public nonReentrant {
        require(
            userInfo[msg.sender].isStaker == true ||
                userInfo[msg.sender].isClaimAferUnstake == true,
            "user not staked"
        );
        (,uint256 compoundRate,) = data.returnData();
        uint256 compoundTime = block.timestamp -
            userInfo[msg.sender].lastStakeUnstakeTimestamp;
        require(compoundTime >= compoundRate, "wait for next compound"); //86400

        rewardCalculation(msg.sender);
        uint256 reward = userInfo[msg.sender].lastClaimedReward +
            userInfo[msg.sender].autoClaimWithStakeUnstake;
        uint256 _vyncPerBusd = vyncPerBusd();
        reward = reward * _vyncPerBusd;
        reward = reward / 1e18;

        require(
            vync.balanceOf(address(this)) >= reward,
            "reward token not available into contract"
        );
        vync.transfer(msg.sender, reward);
        emit rewardClaim(msg.sender, reward);
        userInfo[msg.sender].autoClaimWithStakeUnstake = 0;
        userInfo[msg.sender].lastClaimTimestamp = block.timestamp;

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
        bool isClaim = userInfo[msg.sender].isClaimAferUnstake;
        if (isClaim == true) {
            userInfo[msg.sender].pendingRewardAfterFullyUnstake = 0;
            userInfo[msg.sender].isClaimAferUnstake = false;
        }
    }

    function vyncPerBusd() public view returns (uint256 _vyncPerBusd) {
        uint256 _busd = busd.balanceOf(lpToken);
        uint256 _vync = vync.balanceOf(lpToken);
        _vync = _vync * 1e18;

        _vyncPerBusd = _vync / _busd;
    }

    function vyncRateInBusd() public view returns (uint256 _vyncRateInBusd) {
        uint256 _busd = busd.balanceOf(lpToken);
        uint256 _vync = vync.balanceOf(lpToken);
        _vync = _vync / 1e4;

        _vyncRateInBusd = _busd / _vync;
    }

    function totalStake() external view returns (uint256 stakingAmount) {
        stakingAmount = s;
    }

    function totalUnstake() external view returns (uint256 unstakingAmount) {
        unstakingAmount = u;
    }

    function withdrawVync(uint256 _amount, address _to) external onlyOwner {
        vync.transfer(_to, _amount);
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
        return
            sqrt(
                reserveIn.mul(userIn.mul(399000000) + reserveIn.mul(399000625))
            ).sub(reserveIn.mul(19975)) / 19950;
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
        // else z = 0
    }

    function swapBusdToVync(uint256 amountToSwap)
        internal
        returns (uint256 amountOut)
    {
        uint256 vyncBalanceBefore = vync.balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            getBusdVyncRoute(),
            address(this),
            block.timestamp
        );
        amountOut = vync.balanceOf(address(this)).sub(vyncBalanceBefore);
    }

    function swapVyncToBusd(uint256 amountToSwap)
        internal
        returns (uint256 amountOut)
    {
        uint256 busdBalanceBefore = busd.balanceOf(address(this)); // remove for testing
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            getVyncBusdRoute(),
            address(this),
            block.timestamp
        );
        amountOut = busd.balanceOf(address(this)).sub(busdBalanceBefore);
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
        uint256 amount0 = lp.mul(balance0) / _totalSupply;
        uint256 amount1 = lp.mul(balance1) / _totalSupply;
        // convert amount0 -> amount1
        amount = amount1.add(amount0.mul(balance1).div(balance0));
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
        lpNeeded = amount.mul(getSwappingPair().totalSupply()).div(res1).div(2);
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
        amountVync = vync.balanceOf(address(this)).sub(vyncBalanceBefore);
    }
}
