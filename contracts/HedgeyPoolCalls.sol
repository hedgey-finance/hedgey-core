pragma solidity ^0.6.12;

import libraries.sol;


interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
}


interface IHedgeySwap {
    function hedgeyCallSwap(address payable originalOwner, uint _c, uint _totalPurchase, address[] memory path, bool cashBack) external;
}

contract HedgeyCalls is ReentrancyGuard {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    address public asset;
    address public pymtCurrency;
    uint public assetDecimals;
    address public uniPair; 
    address public unindex0;
    address public unindex1;
    address payable public weth = 0xc778417E063141139Fce010982780140Aa0cD5Ab; //weth address    
    uint public fee;
    address payable public feeCollector;
    uint public c = 0;
    address public uniFactory = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f; //AMM factory address
    bool private assetWeth;
    bool private pymtWeth;
    bool public cashCloseOn;
    

    constructor(address _asset, address _pymtCurrency, address payable _feeCollector, uint _fee) public {
        asset = _asset;
        pymtCurrency = _pymtCurrency;
        feeCollector = _feeCollector;
        fee = _fee;
        assetDecimals = IERC20(_asset).decimals();
        uniPair = IUniswapV2Factory(uniFactory).getPair(asset, pymtCurrency);
        if (uniPair == address(0x0)) {
            cashCloseOn = false;
        } else {
            cashCloseOn = true;
        }
        
        if (_asset == weth) {
            assetWeth = true;
            pymtWeth = false;
        } else if (_pymtCurrency == weth) {
            assetWeth = false;
            pymtWeth = true;
        } else {
            assetWeth = false;
            pymtWeth = false;
        }
    }
    
    struct Call {
        address payable short;
        uint assetAmt;
        uint minimumPurchase;
        uint strike;
        uint totalPurch;
        uint price;
        uint expiry;
        bool open;
        bool tradeable;
        address payable long;
        bool exercised;
    }

    
    mapping (uint => Call) public calls;

    
    //internal and setup functions

    receive() external payable {    
    }

    function depositPymt(bool _isWeth, address _token, address _sender, uint _amt) internal {
        if (_isWeth) {
            require(msg.value == _amt, "deposit issue: sending in wrong amount of eth");
            IWETH(weth).deposit{value: _amt}();
            assert(IWETH(weth).transfer(address(this), _amt));
        } else {
            SafeERC20.safeTransferFrom(IERC20(_token), _sender, address(this), _amt);
        }
    }

    function withdrawPymt(bool _isWeth, address _token, address payable to, uint _amt) internal {
        if (_isWeth && (!Address.isContract(to))) {
            //if the address is a contract - then we should actually just send WETH out to the contract, else send the wallet eth
            IWETH(weth).withdraw(_amt);
            to.transfer(_amt);
        } else {
            SafeERC20.safeTransfer(IERC20(_token), to, _amt);
        }
    }

    function transferPymt(bool _isWETH, address _token, address from, address payable to, uint _amt) internal {
        if (_isWETH) {
            if (!Address.isContract(to)) {
                to.transfer(_amt);
            } else {
                // we want to deliver WETH from ETH here for better handling at contract
                IWETH(weth).deposit{value: _amt}();
                assert(IWETH(weth).transfer(to, _amt));
            }
        } else {
            SafeERC20.safeTransferFrom(IERC20(_token), from, to, _amt);         
        }
    }

    function transferPymtWithFee(bool _isWETH, address _token, address from, address payable to, uint _total) internal {
        uint _fee = (_total * fee).div(1e4);
        uint _amt = _total.sub(_fee);
        if (_isWETH) {
            require(msg.value == _total, "transfer issue: wrong amount of eth sent");
        }
        transferPymt(_isWETH, _token, from, to, _amt); //transfer the stub to recipient
        transferPymt(_isWETH, _token, from, feeCollector, _fee); //transfer fee to fee collector
    }


    //admin function to update the fee amount
    function changeFee(uint _fee) external {
        require(msg.sender == feeCollector);
        fee = _fee;
    }

    function changeCollector(address payable _collector) external {
        require(msg.sender == feeCollector);
        feeCollector = _collector;
    }

    //function anyone can call after the contract is set to update if there was no AMM before but now there is
    function updateAMM() public {
        uniPair = IUniswapV2Factory(uniFactory).getPair(asset, pymtCurrency);
        if (uniPair == address(0x0)) {
            cashCloseOn = false;
        } else {
            cashCloseOn = true;
        }
        emit AMMUpdate(cashCloseOn);
        
    }

    //CALL FUNCTIONS GOING HERE**********************************************************

    //function for someone wanting to buy a new call
    function newBid(uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public {
        uint _totalPurch = _assetAmt.mul(_strike).div(10 ** assetDecimals);
        require(_totalPurch > 0, "c: totalPurchase error: too small amount");
        uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
        require(balCheck >= _price, "c: not enough cash to bid");
        depositPymt(pymtWeth, pymtCurrency, msg.sender, _price); 
        calls[c++] = Call(address(0x0), _assetAmt, _assetAmt, _strike, _totalPurch, _price, _expiry, false, true, msg.sender, false);
        emit NewBid(c.sub(1), _assetAmt, _assetAmt, _strike, _price, _expiry);
    }
    
    //function to cancel a new bid
    function cancelNewBid(uint _c) public nonReentrant {
        Call storage call = calls[_c];
        require(msg.sender == call.long, "c: only long can cancel a bid");
        require(!call.open, "c: call already open");
        require(!call.exercised, "c: call already exercised");
        require(call.short == address(0x0), "c: this is not a new bid");
        call.tradeable = false;
        call.exercised = true;
        withdrawPymt(pymtWeth, pymtCurrency, call.long, call.price);
        emit OptionCancelled(_c);
    }

    
    function sellOpenOptionToNewBid(uint _c, uint _d, uint _price) payable public nonReentrant {
        Call storage openCall = calls[_c];
        Call storage newBid = calls[_d];
        require(_c != _d, "c: wrong sale function");
        require(_price == newBid.price, "c: price changed before you could execute");
        require(msg.sender == openCall.long, "c: you dont own this");
        require(openCall.strike == newBid.strike, "c: not the right strike");
        require(openCall.assetAmt == newBid.assetAmt, "c: not the right assetAmt");
        require(openCall.expiry == newBid.expiry, "c: not the right expiry");
        require(newBid.short == address(0x0), "c: this is not a new bid"); //newBid always sets the short address to 0x0
        require(openCall.open && !newBid.open && newBid.tradeable && !openCall.exercised && !newBid.exercised && openCall.expiry > now && newBid.expiry > now, "something is wrong");
        newBid.exercised = true;
        newBid.tradeable = false;
        uint feePymt = (newBid.price * fee).div(1e4);
        uint shortPymt = newBid.price.sub(feePymt);
        withdrawPymt(pymtWeth, pymtCurrency, openCall.long, shortPymt);
        SafeERC20.safeTransfer(IERC20(pymtCurrency), feeCollector, feePymt);
        openCall.long = newBid.long;
        openCall.price = newBid.price;
        openCall.tradeable = false;
        emit OpenOptionSold( _c, _d, openCall.long, _price);
    }

    //function for someone to write the call for the open bid
    //, uint _strike, uint _assetAmt, uint _price, uint _expiry
    function sellNewOption(uint _c, uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public nonReentrant {
        Call storage call = calls[_c];
        require(call.strike == _strike && call.assetAmt == _assetAmt && call.price == _price && call.expiry == _expiry, "c details issue: something changed");
        require(call.short == address(0x0));
        require(msg.sender != call.long, "c: you are the long");
        require(call.expiry > now, "c: This is already expired");
        require(call.tradeable, "c: not tradeable");
        require(!call.open, "c: call already open");
        require(!call.exercised, "c: this has been exercised");
        uint feePymt = (call.price * fee).div(1e4);
        uint shortPymt = (call.price).sub(feePymt);
        uint balCheck = assetWeth ? msg.value : IERC20(asset).balanceOf(msg.sender);
        require(balCheck >= call.assetAmt, "c: not enough cash to bid");
        depositPymt(assetWeth, asset, msg.sender, call.assetAmt);
        SafeERC20.safeTransfer(IERC20(pymtCurrency), feeCollector, feePymt);
        withdrawPymt(pymtWeth, pymtCurrency, msg.sender, shortPymt);
        call.short = msg.sender;
        call.tradeable = false;
        call.open = true;
        emit NewOptionSold(_c);
    }


    function changeNewOption(uint _c, uint _assetAmt, uint _minimumPurchase, uint _strike, uint _price, uint _expiry) payable public nonReentrant {
        Call storage call = calls[_c];
        require(call.long == msg.sender, "c: you do not own this call");
        require(!call.exercised, "c: this has been exercised");
        require(!call.open, "c: this is already open");
        require(call.tradeable, "c: this is not a tradeable option");
        uint _totalPurch = _assetAmt.mul(_strike).div(10 ** assetDecimals);
        require(_totalPurch > 0, "c: totalPurchase error: too small amount");
        require(_minimumPurchase.mul(_strike).div(10 ** assetDecimals) > 0, "c: minimum purchase error, too small of a minimum");
        //lets check if this is a new ask or new bid
        //if its a newAsk
        if (msg.sender == call.short) {
            uint refund = (call.assetAmt > _assetAmt) ? call.assetAmt.sub(_assetAmt) : _assetAmt.sub(call.assetAmt);
            call.strike = _strike;
            call.price = _price;
            call.expiry = _expiry;
            call.minimumPurchase = _minimumPurchase;
            call.totalPurch = _totalPurch;
            call.tradeable = true;
            if (call.assetAmt > _assetAmt) {
                call.assetAmt = _assetAmt;
                withdrawPymt(assetWeth, asset, call.short, refund);
            } else if (call.assetAmt < _assetAmt) {
                call.assetAmt = _assetAmt;
                uint balCheck = assetWeth ? msg.value : IERC20(asset).balanceOf(msg.sender);
                require(balCheck >= refund, "c: not enough to change this call option");
                depositPymt(assetWeth, asset, msg.sender, refund);
            }
            
            emit OptionChanged(_c, _assetAmt, _strike, _price, _expiry);

        } else if (call.short == address(0x0)) {
            //its a newBid
            uint refund = (_price > call.price) ? _price.sub(call.price) : call.price.sub(_price);
            call.assetAmt = _assetAmt;
            call.minimumPurchase = _assetAmt;
            call.strike = _strike;
            call.expiry = _expiry;
            call.totalPurch = _totalPurch;
            call.tradeable = true;
            if (_price > call.price) {
                call.price = _price;
                uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
                require(balCheck >= refund, "c: not enough cash to bid");
                depositPymt(pymtWeth, pymtCurrency, msg.sender, refund);
            } else if (_price < call.price) {
                call.price = _price;
                withdrawPymt(pymtWeth, pymtCurrency, call.long, refund);
            }
            
            emit OptionChanged(_c, _assetAmt, _strike, _price, _expiry);    
        }
           
    }

    //function to write a new call
    function newAsk(uint _assetAmt, uint _minimumPurchase, uint _strike, uint _price, uint _expiry) payable public {
        uint _totalPurch = _assetAmt.mul(_strike).div(10 ** assetDecimals);
        require(_totalPurch > 0, "c: totalPurchase error: too small amount");
        require(_minimumPurchase.mul(_strike).div(10 ** assetDecimals) > 0, "c: minimum purchase error, too small of a min");
        require(_assetAmt % _minimumPurchase == 0, "c: asset amount needs to be a multiple of the minimum");
        uint balCheck = assetWeth ? msg.value : IERC20(asset).balanceOf(msg.sender);
        require(balCheck >= _assetAmt, "c: not enough to sell this call option");
        depositPymt(assetWeth, asset, msg.sender, _assetAmt);
        calls[c++] = Call(msg.sender, _assetAmt, _minimumPurchase, _strike, _totalPurch, _price, _expiry, false, true, msg.sender, false);
        emit NewAsk(c.sub(1), _assetAmt, _minimumPurchase, _strike, _price, _expiry);
    }


    //function to cancel a new ask from writter side
    function cancelNewAsk(uint _c) public nonReentrant {
        Call storage call = calls[_c];
        require(msg.sender == call.short && msg.sender == call.long, "c: only short can change an ask");
        require(!call.open, "c: call already open");
        require(!call.exercised, "c: call already exercised");
        call.tradeable = false;
        call.exercised = true;
        withdrawPymt(assetWeth, asset, call.short, call.assetAmt);
        emit OptionCancelled(_c);
    }
    
    //function to purchase a new call that hasn't changed hands yet
    //, uint _strike, uint _assetAmt, uint _price, uint _expiry
    function buyNewOption(uint _c, uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public {
        Call storage call = calls[_c];
        require(call.strike == _strike && _assetAmt > 0 && call.price == _price && call.expiry == _expiry, "c details issue: something changed");
        require(msg.sender != call.short, "c: you cannot buy this");
        require(call.short != address(0x0) && call.short == call.long, "c: this option is not a new ask");
        require(call.expiry > now, "c: This call is already expired");
        require(!call.exercised, "c: This has already been exercised");
        require(call.tradeable, "c: This isnt tradeable yet");
        require(!call.open, "c: This call is already open");
        require(_assetAmt >= call.minimumPurchase, "purchase size does not meet minimum");
        if (_assetAmt == call.assetAmt) {
            uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
            require(balCheck >= call.price, "c: not enough to sell this call option");
            transferPymtWithFee(pymtWeth, pymtCurrency, msg.sender, call.short, _price);
        } else {
            uint proRataPurchase = _assetAmt.mul(10 ** assetDecimals).div(call.assetAmt);
            uint proRataPrice = _price.mul(proRataPurchase).div(10 ** assetDecimals);
            uint remainingPrice = _price.sub(proRataPrice);
            uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
            require(balCheck >= proRataPrice, "c: not enough to sell this call option");
            uint proRataTotalPurchase = call.totalPurch.mul(proRataPurchase).div(10 ** assetDecimals);
            require(proRataTotalPurchase > 0 && call.totalPurch.sub(proRataTotalPurchase) > 0, "c: pro rata purchase error");
            transferPymtWithFee(pymtWeth, pymtCurrency, msg.sender, call.short, proRataPrice);
            //setup new call
            calls[c++] = Call(call.long, call.assetAmt.sub(_assetAmt), call.minimumPurchase, call.strike, call.totalPurch.sub(proRataTotalPurchase), remainingPrice, _expiry, false, true, call.long, false);
            emit NewAsk(c.sub(1), call.assetAmt.sub(_assetAmt), call.minimumPurchase, _strike, remainingPrice, _expiry);
            call.assetAmt = _assetAmt;
            call.price = proRataPrice;
            call.totalPurch = proRataTotalPurchase;
        }
        
        call.open = true;
        call.long = msg.sender;
        call.tradeable = false;
        emit NewOptionBought(_c);
    }

    
    /**function to buy an openAsk or newAsk and then replace the long from one position with the long of the other position and remove openShort from obligation */
    function buyOptionFromAsk(uint _c, uint _d, uint _price) payable public nonReentrant {
        Call storage openShort = calls[_c];
        Call storage ask = calls[_d];
        require(msg.sender == openShort.short, "c: your not the short");
        require(ask.short != address(0x0), "c: this is a newBid");
        require(_price == ask.price, "c: price changed before executed");
        require(ask.tradeable && !ask.exercised && ask.expiry > now,"c: ask issue");
        require(openShort.open && !openShort.exercised && openShort.expiry > now, "c: short issue");
        require(openShort.strike == ask.strike, "c: strikes do not match");
        require(openShort.assetAmt == ask.assetAmt, "c: asset amount does not match");
        require(openShort.expiry == ask.expiry, "c: expiry does not match");
        require(_c != _d, "c: wrong function to buyback");
        //openShort pays the ask
        uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
        require(balCheck >= ask.price, "c: not enough to buy this put");
        transferPymtWithFee(pymtWeth, pymtCurrency, openShort.short, ask.long, _price); //if newAsk then ask.long == ask.short, if openAsk then ask.long is the one receiving the payment
        //all the checks having been matched - now we assign the openAsk short to the openShort short position
        //then we close out the openAsk position
        ask.exercised = true;
        ask.tradeable = false;
        ask.open = false;
        //now withdraw the openShort's asset back to them
        withdrawPymt(assetWeth, asset, openShort.short, openShort.assetAmt);
        openShort.short = ask.short;
        emit OpenShortRePurchased( _c, _d, openShort.short, _price);
    }
    


    //this function lets the long set a new price on the call - typically used for existing open positions
    function setPrice(uint _c, uint _price, bool _tradeable) public {
        Call storage call = calls[_c];
        require((msg.sender == call.long && msg.sender == call.short) || (msg.sender == call.long && call.open), "c: you cant change the price");
        require(call.expiry > now, "c: already expired");
        require(!call.exercised, "c: already expired");
        call.price = _price; 
        call.tradeable = _tradeable;
        emit PriceSet(_c, _price, _tradeable);
    }



    //use this function to sell existing calls
    //uint _strike, uint _assetAmt, uint _price, uint _expiry
    function buyOpenOption(uint _c, uint _assetAmt, uint _strike, uint _price, uint _expiry) payable public nonReentrant {
        Call storage call = calls[_c];
        require(call.strike == _strike && call.assetAmt == _assetAmt && call.price == _price && call.expiry == _expiry, "c: something changed");
        require(msg.sender != call.long, "c: You already own this");
        require(call.open, "c: This call isnt opened yet");
        require(call.expiry >= now, "c: This call is already expired");
        require(!call.exercised, "c: This has already been exercised");
        require(call.tradeable, "c: not tradeable");
        uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
        require(balCheck >= call.price, "c: not enough to sell this call option");
        transferPymtWithFee(pymtWeth, pymtCurrency, msg.sender, call.long, call.price);
        if (msg.sender == call.short) {
            call.exercised = true;
            call.open = false;
            withdrawPymt(assetWeth, asset, call.short, call.assetAmt);
        }
        call.tradeable = false;
        call.long = msg.sender;
        emit OpenOptionPurchased(_c);
    }


    //this is the basic exercise execution function that needs to be invoked prior to maturity to receive the physical asset
    function exercise(uint _c) payable public nonReentrant {
        Call storage call = calls[_c];
        require(call.open, "c: This isnt open");
        require(call.expiry >= now, "c: This call is already expired");
        require(!call.exercised, "c: This has already been exercised!");
        require(msg.sender == call.long, "c: You dont own this call");
        uint balCheck = pymtWeth ? msg.value : IERC20(pymtCurrency).balanceOf(msg.sender);
        require(balCheck >= call.totalPurch, "c: not enough to exercise this call option");
        call.exercised = true;
        call.open = false;
        call.tradeable = false;
        if(pymtWeth) {
            require(msg.value == call.totalPurch,"eth mismatch on value to purchase the asset");
        }
        transferPymt(pymtWeth, pymtCurrency, msg.sender, call.short, call.totalPurch);   
        withdrawPymt(assetWeth, asset, call.long, call.assetAmt);
        emit OptionExercised(_c, false);
    }


    //this is the exercise alternative for ppl who want to receive payment currency instead of the underlying asset
    function cashClose(uint _c, bool cashBack) payable public nonReentrant {
        require(cashCloseOn, "c: this pair cannot be cash closed");
        Call storage call = calls[_c];
        require(call.open, "c: This isnt open");
        require(call.expiry >= now, "c: This call is already expired");
        require(!call.exercised, "c: This has already been exercised!");
        require(msg.sender == call.long, "c: You dont own this call");
   
        uint assetIn = estIn(call.totalPurch);
        require(assetIn < (call.assetAmt), "c: Underlying is not in the money");
        
        address to = pymtWeth ? address(this) : call.short;
        call.exercised = true;
        call.open = false;
        call.tradeable = false;
        swap(asset, call.totalPurch, assetIn, to);
        if (pymtWeth) {
            withdrawPymt(pymtWeth, pymtCurrency, call.short, call.totalPurch);
        }
        
        call.assetAmt -= assetIn;
        
        if (cashBack) {
            
            uint cashEst = estCashOut(call.assetAmt);
            address _to = pymtWeth ? address(this) : call.long;
            swap(asset, cashEst, call.assetAmt, _to);
            if (pymtWeth) {
                withdrawPymt(pymtWeth, pymtCurrency, call.long, cashEst); 
            }
        } else {
            withdrawPymt(assetWeth, asset, call.long, call.assetAmt);
        }
        
        emit OptionExercised(_c, true);
    }


    

    //returns an expired call back to the short
    function returnExpired(uint _c) public nonReentrant {
        Call storage call = calls[_c];
        require(!call.exercised, "c: This has been exercised");
        require(call.expiry < now, "c: Not expired yet"); 
        require(msg.sender == call.short, "c: You cant do that");
        call.tradeable = false;
        call.open = false;
        call.exercised = true;
        withdrawPymt(assetWeth, asset, call.short, call.assetAmt);
        emit OptionReturned(_c);
    }

    //function to roll expired call into a new short contract
    function rollExpired(uint _c, uint _assetAmt, uint _minimumPurchase, uint _newStrike, uint _price, uint _newExpiry) payable public nonReentrant {
        Call storage call = calls[_c]; 
        require(!call.exercised, "c: This has been exercised");
        require(call.expiry < now, "c: Not expired yet"); 
        require(msg.sender == call.short, "c: You cant do that");
        require(_newExpiry > now, "c: this is already in the past");
        uint refund = (call.assetAmt > _assetAmt) ? call.assetAmt.sub(_assetAmt) : _assetAmt.sub(call.assetAmt);
        uint _totalPurch = (_assetAmt).mul(_newStrike).div(10 ** assetDecimals);
        require(_totalPurch > 0, "c: totalPurchase error: too small amount");
        call.tradeable = false;
        call.open = false;
        call.exercised = true;
        if (call.assetAmt > _assetAmt) {
            withdrawPymt(assetWeth, asset, call.short, refund); 
        } else if (call.assetAmt < _assetAmt) {
            uint balCheck = assetWeth ? msg.value : IERC20(asset).balanceOf(msg.sender);
            require(balCheck >= refund, "c: not enough to change this call option");
            depositPymt(assetWeth, asset, msg.sender, refund); 
        }
        
        calls[c++] = Call(msg.sender, _assetAmt, _minimumPurchase, _newStrike, _totalPurch, _price, _newExpiry, false, true, msg.sender, false);
        emit OptionRolled(_c, c.sub(1), _assetAmt, _minimumPurchase, _newStrike, _price, _newExpiry);
    }


    //function to transfer an owned call (only long) for the primary purpose of leveraging external swap functions to physically exercise in the case of no cash closing
    function transferAndSwap(uint _c, address payable newOwner, address[] memory path, bool cashBack) external {
        Call storage call = calls[_c];
        require(call.expiry >= block.timestamp, "c: This call is already expired");
        require(!call.exercised, "c: This has already been exercised!");
        require(call.open, "c: only open calls can be transferred");
        require(msg.sender == call.long, "c: You dont own this call");
        require(newOwner != call.short, "c: you cannot transfer to the short");
        call.long = newOwner; //set long to new owner
        if (path.length > 0) {
            require(Address.isContract(newOwner));
            require(path.length > 2, "use the normal cash close method for single pool swaps");
            //swapping from asset to payment currency - need asset first and payment currency last in the path
            require(path[0] == asset && path[path.length - 1] == pymtCurrency, "your not swapping the right currencies");
            IHedgeySwap(newOwner).hedgeyCallSwap(msg.sender, _c, call.totalPurch, path, cashBack);
        }
        
        emit OptionTransferred(_c, newOwner);
    }

    

    //************SWAP SPECIFIC FUNCTIONS USED FOR THE CASH CLOSE METHODS***********************/

    //function to swap from this contract to uniswap pool
    function swap(address token, uint out, uint _in, address to) internal {
        SafeERC20.safeTransfer(IERC20(token), uniPair, _in); //sends the asset amount in to the swap
        address token0 = IUniswapV2Pair(uniPair).token0();
        if (token == token0) {
            IUniswapV2Pair(uniPair).swap(0, out, to, new bytes(0));
        } else {
            IUniswapV2Pair(uniPair).swap(out, 0, to, new bytes(0));
        }
        
    }

    function estCashOut(uint amountIn) public view returns (uint amountOut) {
        (uint resA, uint resB,) = IUniswapV2Pair(uniPair).getReserves();
        address token1 = IUniswapV2Pair(uniPair).token1();
        amountOut = (token1 == pymtCurrency) ? UniswapV2Library.getAmountOut(amountIn, resA, resB) : UniswapV2Library.getAmountOut(amountIn, resB, resA);
    }

    function estIn(uint amountOut) public view returns (uint amountIn) {
        (uint resA, uint resB,) = IUniswapV2Pair(uniPair).getReserves();
        address token1 = IUniswapV2Pair(uniPair).token1();
        amountIn = (token1 == pymtCurrency) ? UniswapV2Library.getAmountIn(amountOut, resA, resB) : UniswapV2Library.getAmountIn(amountOut, resB, resA);
    }

   /***events*****/
    event NewBid(uint _i, uint _assetAmt, uint _minimumPurchase, uint _strike, uint _price, uint _expiry);
    event NewAsk(uint _i, uint _assetAmt, uint _minimumPurchase, uint _strike, uint _price, uint _expiry);
    event NewOptionSold(uint _i);
    event NewOptionBought(uint _i);
    event OpenOptionSold(uint _i, uint _j, address _long, uint _price);
    event OpenShortRePurchased(uint _i, uint _j, address _short, uint _price);
    event OpenOptionPurchased(uint _i);
    event OptionChanged(uint _i, uint _assetAmt, uint _strike, uint _price, uint _expiry);
    event PriceSet(uint _i, uint _price, bool _tradeable);
    event OptionExercised(uint _i, bool cashClosed);
    event OptionRolled(uint _i, uint _j, uint _assetAmt, uint _minimumPurchase, uint _strike, uint _price, uint _expiry);
    event OptionReturned(uint _i);
    event OptionCancelled(uint _i);
    event OptionTransferred(uint _i, address newOwner);
    event AMMUpdate(bool _cashCloseOn);
}


pragma solidity ^0.6.12;

contract HedgeyCallsFactory {
    
    mapping(address => mapping(address => address)) public pairs;
    address[] public totalContracts;
    address payable public collector;
    uint public fee;
    
    

    constructor (address payable _collector, uint _fee) public {
        collector = _collector;
        fee = _fee;
       
    }
    
    function changeFee(uint _newFee) public {
        require(msg.sender == collector, "youre not the collector");
        fee = _newFee;
    }

    function changeCollector(address payable _collector) public {
        require(msg.sender == collector, "youre not the collector");
        collector = _collector;
    }

    
    function getPair(address asset, address pymtCurrency) public view returns (address pair) {
        pair = pairs[asset][pymtCurrency];
    }

    function createContract(address asset, address pymtCurrency) public {
        require(asset != pymtCurrency, "same currencies");
        require(pairs[asset][pymtCurrency] == address(0), "contract exists");
        HedgeyCalls callContract = new HedgeyCalls(asset, pymtCurrency, collector, fee);
        pairs[asset][pymtCurrency] = address(callContract);
        totalContracts.push(address(callContract));
        emit NewPairCreated(asset, pymtCurrency, address(callContract));
    }

    event NewPairCreated(address _asset, address _pymtCurrency, address _pair);
}

