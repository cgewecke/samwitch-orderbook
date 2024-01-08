// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IBrushToken} from "./interfaces/IBrushToken.sol";

import {BokkyPooBahsRedBlackTreeLibrary} from "./BokkyPooBahsRedBlackTreeLibrary.sol";

contract OrderBook is ERC1155Holder, UUPSUpgradeable, OwnableUpgradeable {
  using BokkyPooBahsRedBlackTreeLibrary for BokkyPooBahsRedBlackTreeLibrary.Tree;

  event OrdersPlaced(LimitOrder[] orders, address from);
  event OrdersMatched(uint[] orderIds, uint[] quantities, address taker);
  event OrdersCancelled(uint[] orderIds);
  event AddedToBook(bool isBuy, uint orderId, uint quantity, uint price);
  event ClaimedTokens(address maker, uint[] orderIds, uint amount);
  event ClaimedNFTs(address maker, uint[] orderIds, uint[] tokenIds, uint[] amounts);
  event SetTokenIdInfos(uint[] tokenIds, TokenIdInfo[] tokenIdInfos);

  error NotERC1155();
  error NoQuantity();
  error OrderNotFound();
  error PriceNotMultipleOfTick(uint tick);
  error TokenDoesntExist(uint tokenId);
  error PriceZero();
  error LengthMismatch();
  error QuantityRemainingTooLow();
  error NotMaker();
  error NothingToClaim();
  error TooManyOrdersHit();

  enum OrderSide {
    Buy,
    Sell
  }

  struct LimitOrder {
    OrderSide side;
    uint tokenId;
    uint64 price;
    uint24 quantity;
  }

  struct OrderBookEntryHelper {
    address maker;
    uint24 quantity;
    uint40 id;
  }

  struct TokenIdInfo {
    uint128 tick;
    uint128 minQuantity;
  }

  struct CancelOrderInfo {
    OrderSide side;
    uint tokenId;
    uint64 price;
  }

  IERC1155 public nft;
  IBrushToken public token;

  address public devAddr;
  uint8 public devFee; // Base 10000, max 2.55%
  uint8 public burntFee;
  uint16 public royaltyFee;
  uint16 public maxOrdersPerPrice;
  uint40 public nextOrderId;
  address public royaltyRecipient;

  mapping(uint tokenId => TokenIdInfo tokenIdInfo) public tokenIdInfos;

  mapping(uint tokenId => BokkyPooBahsRedBlackTreeLibrary.Tree) public asks;
  mapping(uint tokenId => BokkyPooBahsRedBlackTreeLibrary.Tree) public bids;
  mapping(uint tokenId => mapping(uint price => bytes32[] packedOrders)) public askValues; // quantity (uint24), id (uint40) 4x packed of these
  mapping(uint tokenId => mapping(uint price => bytes32[] packedOrders)) public bidValues; // quantity (uint24), id (uint40) 4x packed of these
  mapping(uint orderId => address maker) public orderBookIdToMaker;

  mapping(uint40 orderId => uint amount) private brushClaimable; // TODO Pack these?
  mapping(uint40 orderId => mapping(uint tokenId => uint amount)) private tokenIdsClaimable;

  uint private constant MAX_ORDERS_HIT = 500;
  uint private constant NUM_ORDERS_PER_SEGMENT = 4;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(IERC1155 _nft, address _token, address _devAddr) external initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(msg.sender);

    nft = _nft;
    if (!_nft.supportsInterface(type(IERC1155).interfaceId)) {
      revert NotERC1155();
    }
    token = IBrushToken(_token);
    updateRoyaltyFee();

    devFee = 30; // 30 = 0.3% fee,
    devAddr = _devAddr;
    burntFee = 30; // 30 = 0.3% fee,
    maxOrdersPerPrice = 100; // This includes inside segments, so num segments = maxOrdersPrice / NUM_ORDERS_PER_SEGMENT

    nextOrderId = 1;
  }

  function limitOrders(LimitOrder[] calldata _limitOrders) external {
    uint royalty;
    uint dev;
    uint burn;
    uint brushTransferToUs;
    uint brushTransferFromUs;
    uint lengthToUs;
    uint[] memory idsToUs = new uint[](_limitOrders.length);
    uint[] memory amountsToUs = new uint[](_limitOrders.length);
    uint lengthFromUs;
    uint[] memory idsFromUs = new uint[](_limitOrders.length);
    uint[] memory amountsFromUs = new uint[](_limitOrders.length);

    // This is done here so that th it can be used in many limit orders without wasting too much space
    uint[] memory orderIdsPool = new uint[](MAX_ORDERS_HIT);
    uint[] memory quantitiesPool = new uint[](MAX_ORDERS_HIT);

    for (uint i = 0; i < _limitOrders.length; ++i) {
      OrderSide side = _limitOrders[i].side;
      uint tokenId = _limitOrders[i].tokenId;
      uint quantity = _limitOrders[i].quantity;
      uint price = _limitOrders[i].price;
      (uint24 quantityRemaining, uint cost) = _makeLimitOrder(_limitOrders[i], orderIdsPool, quantitiesPool);

      if (side == OrderSide.Buy) {
        brushTransferToUs += cost + uint(price) * quantityRemaining;
        (uint _royalty, uint _dev, uint _burn) = _calcFees(cost);
        royalty += _royalty;
        dev += _dev;
        burn += _burn;
        // Transfer the NFTs straight to the user
        if (cost > 0) {
          idsFromUs[lengthFromUs] = tokenId;
          amountsFromUs[lengthFromUs++] = quantity - quantityRemaining;
        }
      } else {
        // Selling, transfer all NFTs to us
        idsToUs[lengthToUs] = tokenId;
        amountsToUs[lengthToUs++] = quantity;

        // Transfer tokens to the seller if any have sold
        if (cost > 0) {
          (uint _royalty, uint _dev, uint _burn) = _calcFees(cost);
          royalty += _royalty;
          dev += _dev;
          burn += _burn;
          uint fees = _royalty + _dev + _burn;
          brushTransferFromUs += cost - fees;
        }
      }
    }

    assembly ("memory-safe") {
      mstore(idsToUs, lengthToUs)
      mstore(amountsToUs, lengthToUs)
      mstore(idsFromUs, lengthFromUs)
      mstore(amountsFromUs, lengthFromUs)
    }

    if (brushTransferToUs > 0) {
      token.transferFrom(msg.sender, address(this), brushTransferToUs);
    }

    if (brushTransferFromUs > 0) {
      _safeTransferFromUs(msg.sender, brushTransferFromUs);
    }

    if (idsToUs.length > 0) {
      nft.safeBatchTransferFrom(msg.sender, address(this), idsToUs, amountsToUs, "");
    }

    if (idsFromUs.length > 0) {
      _safeBatchTransferNFTsFromUs(msg.sender, idsFromUs, amountsFromUs);
    }

    _sendFees(royalty, dev, burn);
    emit OrdersPlaced(_limitOrders, msg.sender);
  }

  function _buyTakeFromOrderBook(
    uint _tokenId,
    uint64 _price,
    uint24 _quantity,
    uint[] memory _orderIdsPool,
    uint[] memory _quantitiesPool
  ) private returns (uint24 quantityRemaining, uint cost) {
    quantityRemaining = _quantity;

    // reset the size
    assembly ("memory-safe") {
      mstore(_orderIdsPool, MAX_ORDERS_HIT)
      mstore(_quantitiesPool, MAX_ORDERS_HIT)
    }

    uint length;
    while (quantityRemaining > 0) {
      uint64 lowestAsk = getLowestAsk(_tokenId);
      if (lowestAsk == 0 || lowestAsk > _price) {
        // No more orders left
        break;
      }

      // Loop through all at this order
      uint numSegmentsFullyConsumed = 0;
      for (uint i = asks[_tokenId].getNode(lowestAsk).tombstoneOffset; i < askValues[_tokenId][lowestAsk].length; ++i) {
        bytes32 packed = askValues[_tokenId][lowestAsk][i];
        uint numOrdersWithinSegmentConsumed;
        uint finalOffset;
        for (uint offset; offset < NUM_ORDERS_PER_SEGMENT; ++offset) {
          uint40 orderId = uint40(uint(packed >> (offset * 64)));
          if (orderId == 0 || quantityRemaining == 0) {
            // No more orders at this price level in this segment
            if (orderId == 0) {
              finalOffset = offset - 1;
            }
            break;
          }
          uint24 quantityL3 = uint24(uint(packed >> (offset * 64 + 40)));
          uint quantityNFTClaimable = 0;
          if (quantityRemaining >= quantityL3) {
            // Consume this whole order
            quantityRemaining -= quantityL3;
            // Is the the last one in the segment being fully consumed?
            if (offset == NUM_ORDERS_PER_SEGMENT - 1 || uint(packed >> ((offset + 1) * 64)) == 0) {
              ++numSegmentsFullyConsumed;
            }
            ++numOrdersWithinSegmentConsumed;
            quantityNFTClaimable = quantityL3;
          } else {
            // Eat into the order
            bytes32 newPacked = bytes32(
              (uint(packed) & ~(uint(0xffffff) << (offset * 64 + 40))) |
                (uint(quantityL3 - quantityRemaining) << (offset * 64 + 40))
            );
            packed = newPacked;
            quantityNFTClaimable = quantityRemaining;
            quantityRemaining = 0;
          }
          finalOffset = offset;
          cost += quantityNFTClaimable * lowestAsk;

          brushClaimable[orderId] += quantityNFTClaimable * lowestAsk;

          _orderIdsPool[length] = orderId;
          _quantitiesPool[length++] = quantityNFTClaimable;

          if (length >= MAX_ORDERS_HIT) {
            revert TooManyOrdersHit();
          }
        }

        if (numOrdersWithinSegmentConsumed != finalOffset + 1) {
          askValues[_tokenId][lowestAsk][i] = bytes32(packed >> (numOrdersWithinSegmentConsumed * 64));
        }
        if (quantityRemaining == 0) {
          break;
        }
      }

      // We consumed all orders at this price, so remove all
      if (
        numSegmentsFullyConsumed ==
        askValues[_tokenId][lowestAsk].length - asks[_tokenId].getNode(lowestAsk).tombstoneOffset
      ) {
        asks[_tokenId].remove(lowestAsk);
        delete askValues[_tokenId][lowestAsk];
      } else {
        // Increase tombstone offset of this price for gas efficiency
        asks[_tokenId].edit(lowestAsk, uint32(numSegmentsFullyConsumed));
      }
    }

    assembly ("memory-safe") {
      mstore(_orderIdsPool, length)
      mstore(_quantitiesPool, length)
    }

    emit OrdersMatched(_orderIdsPool, _quantitiesPool, msg.sender);
  }

  function _sellTakeFromOrderBook(
    uint _tokenId,
    uint _price,
    uint24 _quantity,
    uint[] memory _orderIdsPool,
    uint[] memory _quantitiesPool
  ) private returns (uint24 quantityRemaining, uint cost) {
    quantityRemaining = _quantity;

    // reset the size
    assembly ("memory-safe") {
      mstore(_orderIdsPool, MAX_ORDERS_HIT)
      mstore(_quantitiesPool, MAX_ORDERS_HIT)
    }
    uint length;
    while (quantityRemaining > 0) {
      uint64 highestBid = getHighestBid(_tokenId);
      if (highestBid == 0 || highestBid < _price) {
        // No more orders left
        break;
      }

      // Loop through all at this order
      uint numSegmentsFullyConsumed = 0;
      for (
        uint i = bids[_tokenId].getNode(highestBid).tombstoneOffset;
        i < bidValues[_tokenId][highestBid].length;
        ++i
      ) {
        bytes32 packed = bidValues[_tokenId][highestBid][i];
        uint numOrdersWithinSegmentConsumed;
        uint finalOffset;
        for (uint offset; offset < NUM_ORDERS_PER_SEGMENT; ++offset) {
          uint40 orderId = uint40(uint(packed >> (offset * 64)));
          if (orderId == 0 || quantityRemaining == 0) {
            // No more orders at this price level in this segment
            if (orderId == 0) {
              finalOffset = offset - 1;
            }
            break;
          }
          uint24 quantityL3 = uint24(uint(packed >> (offset * 64 + 40)));
          uint quantityNFTClaimable = 0;
          if (quantityRemaining >= quantityL3) {
            // Consume this whole order
            quantityRemaining -= quantityL3;
            // Is the the last one in the segment being fully consumed?
            if (offset == NUM_ORDERS_PER_SEGMENT - 1 || uint(packed >> ((offset + 1) * 64)) == 0) {
              ++numSegmentsFullyConsumed;
            }
            ++numOrdersWithinSegmentConsumed;
            quantityNFTClaimable = quantityL3;
          } else {
            // Eat into the order
            bytes32 newPacked = bytes32(
              (uint(packed) & ~(uint(0xffffff) << (offset * 64 + 40))) |
                (uint(quantityL3 - quantityRemaining) << (offset * 64 + 40))
            );
            packed = newPacked;
            quantityNFTClaimable = quantityRemaining;
            quantityRemaining = 0;
          }
          finalOffset = offset;
          cost += quantityNFTClaimable * highestBid;

          tokenIdsClaimable[orderId][_tokenId] += quantityNFTClaimable;

          _orderIdsPool[length] = orderId;
          _quantitiesPool[length++] = quantityNFTClaimable;

          if (length >= MAX_ORDERS_HIT) {
            revert TooManyOrdersHit();
          }
        }

        if (numOrdersWithinSegmentConsumed != finalOffset + 1) {
          bidValues[_tokenId][highestBid][i] = bytes32(packed >> (numOrdersWithinSegmentConsumed * 64));
        }
        if (quantityRemaining == 0) {
          break;
        }
      }

      // We consumed all orders at this price level, so remove all
      if (
        numSegmentsFullyConsumed ==
        bidValues[_tokenId][highestBid].length - bids[_tokenId].getNode(highestBid).tombstoneOffset
      ) {
        bids[_tokenId].remove(highestBid); // TODO: A ranged delete would be nice
        delete bidValues[_tokenId][highestBid];
      } else {
        // Increase tombstone offset of this price for gas efficiency
        bids[_tokenId].edit(highestBid, uint32(numSegmentsFullyConsumed));
      }
    }

    assembly ("memory-safe") {
      mstore(_orderIdsPool, length)
      mstore(_quantitiesPool, length)
    }

    emit OrdersMatched(_orderIdsPool, _quantitiesPool, msg.sender);
  }

  function _takeFromOrderBook(
    bool _isBuy,
    uint _tokenId,
    uint64 _price,
    uint24 _quantity,
    uint[] memory _orderIdsPool,
    uint[] memory _quantitiesPool
  ) private returns (uint24 quantityRemaining, uint cost) {
    // Take as much as possible from the order book
    if (_isBuy) {
      (quantityRemaining, cost) = _buyTakeFromOrderBook(_tokenId, _price, _quantity, _orderIdsPool, _quantitiesPool);
    } else {
      (quantityRemaining, cost) = _sellTakeFromOrderBook(_tokenId, _price, _quantity, _orderIdsPool, _quantitiesPool);
    }
  }

  function claimAll(
    uint[] calldata _brushOrderIds,
    uint[] calldata _tokenOrderIds,
    uint[] calldata _tokenIds
  ) external {
    claimTokens(_brushOrderIds);
    claimNFTs(_tokenOrderIds, _tokenIds);
  }

  function claimTokens(uint[] calldata _orderIds) public {
    uint amount;
    for (uint i = 0; i < _orderIds.length; ++i) {
      uint40 orderId = uint40(_orderIds[i]);
      uint orderAmount = brushClaimable[orderId];
      if (orderAmount == 0) {
        revert NothingToClaim();
      }

      address maker = orderBookIdToMaker[orderId];
      if (maker != msg.sender) {
        revert NotMaker();
      }
      amount += orderAmount;
      brushClaimable[orderId] = 0;
    }

    if (amount == 0) {
      revert NothingToClaim();
    }

    (uint royalty, uint dev, uint burn) = _calcFees(amount);
    uint fees = royalty + dev + burn;
    uint amountExclFees;
    if (amount > fees) {
      amountExclFees = amount - fees;
      _safeTransferFromUs(msg.sender, amountExclFees);
    }
    emit ClaimedTokens(msg.sender, _orderIds, amountExclFees);
  }

  function claimNFTs(uint[] calldata _orderIds, uint[] calldata _tokenIds) public {
    if (_orderIds.length != _tokenIds.length) {
      revert LengthMismatch();
    }

    uint[] memory amounts = new uint[](_tokenIds.length);
    for (uint i = 0; i < _tokenIds.length; ++i) {
      uint40 orderId = uint40(_orderIds[i]);
      uint tokenId = _tokenIds[i];
      uint amount = tokenIdsClaimable[orderId][tokenId];
      if (amount == 0) {
        revert NothingToClaim();
      }
      amounts[i] = amount;
      tokenIdsClaimable[orderId][tokenId] = 0;
    }

    emit ClaimedNFTs(msg.sender, _orderIds, _tokenIds, amounts);

    _safeBatchTransferNFTsFromUs(msg.sender, _tokenIds, amounts);
  }

  function cancelOrders(uint[] calldata _orderIds, CancelOrderInfo[] calldata _cancelOrderInfos) external {
    if (_orderIds.length != _cancelOrderInfos.length) {
      revert LengthMismatch();
    }

    for (uint i = 0; i < _cancelOrderInfos.length; ++i) {
      OrderSide side = _cancelOrderInfos[i].side;
      uint tokenId = _cancelOrderInfos[i].tokenId;
      uint64 price = _cancelOrderInfos[i].price;

      if (side == OrderSide.Buy) {
        uint24 quantity = _cancelOrdersSide(_orderIds[i], price, bidValues[tokenId][price], bids[tokenId]);
        // Send the remaining token back to them
        _safeTransferFromUs(msg.sender, quantity * price);
      } else {
        uint24 quantity = _cancelOrdersSide(_orderIds[i], price, askValues[tokenId][price], asks[tokenId]);
        // Send the remaining NFTs back to them
        _safeTransferNFTsFromUs(msg.sender, tokenId, quantity);
      }
    }

    emit OrdersCancelled(_orderIds);
  }

  function updateRoyaltyFee() public {
    bool supportsERC2981 = nft.supportsInterface(type(IERC2981).interfaceId);
    if (supportsERC2981) {
      (address _royaltyRecipient, uint _royaltyFee) = IERC2981(address(nft)).royaltyInfo(1, 10000);
      royaltyRecipient = _royaltyRecipient;
      royaltyFee = uint16(_royaltyFee);
    }
  }

  // TODO: editOrder

  function allOrdersAtPrice(
    OrderSide _side,
    uint _tokenId,
    uint64 _price
  ) external view returns (OrderBookEntryHelper[] memory orderBookEntries) {
    if (_side == OrderSide.Buy) {
      return _allOrdersAtPriceSide(bidValues[_tokenId][_price], bids[_tokenId], _price);
    } else {
      return _allOrdersAtPriceSide(askValues[_tokenId][_price], asks[_tokenId], _price);
    }
  }

  function _allOrdersAtPriceSide(
    bytes32[] storage packedOrderBookEntries,
    BokkyPooBahsRedBlackTreeLibrary.Tree storage _tree,
    uint64 _price
  ) private view returns (OrderBookEntryHelper[] memory orderBookEntries) {
    if (!_tree.exists(_price)) {
      return orderBookEntries;
    }
    uint tombstoneOffset = _tree.getNode(_price).tombstoneOffset;
    orderBookEntries = new OrderBookEntryHelper[](
      (packedOrderBookEntries.length - tombstoneOffset) * NUM_ORDERS_PER_SEGMENT
    );
    uint length;
    for (uint i; i < orderBookEntries.length; ++i) {
      uint packed = uint(packedOrderBookEntries[i / NUM_ORDERS_PER_SEGMENT]);
      uint offset = i % NUM_ORDERS_PER_SEGMENT;
      uint40 id = uint40(packed >> (offset * 64));
      if (id != 0) {
        uint24 quantity = uint24(packed >> (offset * 64 + 40));
        orderBookEntries[length++] = OrderBookEntryHelper({maker: orderBookIdToMaker[id], quantity: quantity, id: id});
      }
    }

    assembly ("memory-safe") {
      mstore(orderBookEntries, length)
    }
  }

  function _cancelOrdersSide(
    uint _orderId,
    uint64 _price,
    bytes32[] storage _packedOrderBookEntries,
    BokkyPooBahsRedBlackTreeLibrary.Tree storage _tree
  ) private returns (uint24 quantity) {
    // Loop through all of them until we hit ours.
    if (!_tree.exists(_price)) {
      revert OrderNotFound();
    }

    uint tombstoneOffset = _tree.getNode(_price).tombstoneOffset;

    (uint index, uint offset) = _find(
      _packedOrderBookEntries,
      tombstoneOffset,
      _packedOrderBookEntries.length,
      _orderId
    );
    if (index == type(uint).max) {
      revert OrderNotFound();
    }

    quantity = uint24(uint(_packedOrderBookEntries[index]) >> (offset * 64 + 40));
    _cancelOrder(_packedOrderBookEntries, _price, index, offset, tombstoneOffset, _tree);
  }

  function _makeLimitOrder(
    LimitOrder calldata _limitOrder,
    uint[] memory _orderIdsPool,
    uint[] memory _quantitiesPool
  ) private returns (uint24 quantityRemaining, uint cost) {
    if (_limitOrder.quantity == 0) {
      revert NoQuantity();
    }

    if (_limitOrder.price == 0) {
      revert PriceZero();
    }

    TokenIdInfo memory tokenIdInfo = tokenIdInfos[_limitOrder.tokenId];
    uint tick = tokenIdInfo.tick;
    if (_limitOrder.price % tick != 0) {
      revert PriceNotMultipleOfTick(tick);
    }

    if (tokenIdInfos[_limitOrder.tokenId].tick == 0) {
      revert TokenDoesntExist(_limitOrder.tokenId);
    }

    bool isBuy = _limitOrder.side == OrderSide.Buy;
    (quantityRemaining, cost) = _takeFromOrderBook(
      isBuy,
      _limitOrder.tokenId,
      _limitOrder.price,
      _limitOrder.quantity,
      _orderIdsPool,
      _quantitiesPool
    );

    if (quantityRemaining != 0 && quantityRemaining < tokenIdInfo.minQuantity) {
      revert QuantityRemainingTooLow();
    }

    // Add the rest to the order book
    if (quantityRemaining > 0) {
      _addToBook(isBuy, _limitOrder.tokenId, _limitOrder.price, quantityRemaining);
    }
  }

  function _addToBookSide(
    mapping(uint price => bytes32[]) storage _packedOrdersPriceMap,
    BokkyPooBahsRedBlackTreeLibrary.Tree storage _tree,
    uint _tokenId,
    uint64 _price,
    uint _orderId,
    uint _quantity,
    int128 _tickIncrement // -1 for buy, +1 for sell
  ) private returns (uint64 price) {
    // Add to the bids section
    price = _price;
    if (!_tree.exists(price)) {
      _tree.insert(price);
    } else {
      uint tombstoneOffset = _tree.getNode(price).tombstoneOffset;
      // Check if this would go over the max number of orders allowed at this price level
      bool lastSegmentFilled = uint(
        _packedOrdersPriceMap[price][_packedOrdersPriceMap[price].length - 1] >> ((NUM_ORDERS_PER_SEGMENT - 1) * 64)
      ) != 0;

      // Check if last segment is full
      if (
        (_packedOrdersPriceMap[price].length - tombstoneOffset) * NUM_ORDERS_PER_SEGMENT >= maxOrdersPerPrice &&
        lastSegmentFilled
      ) {
        // Loop until we find a suitable place to put this
        while (true) {
          price = uint64(uint128(int64(price) + _tickIncrement));
          if (!_tree.exists(price)) {
            _tree.insert(price);
            break;
          } else if (
            (_packedOrdersPriceMap[price].length - tombstoneOffset) * NUM_ORDERS_PER_SEGMENT >= maxOrdersPerPrice &&
            uint(
              _packedOrdersPriceMap[price][_packedOrdersPriceMap[price].length - 1] >>
                ((NUM_ORDERS_PER_SEGMENT - 1) * 64)
            ) !=
            0
          ) {
            break;
          }
        }
      }
    }

    // Read last one
    bytes32[] storage packedOrders = _packedOrdersPriceMap[price];
    bool pushToEnd = true;
    if (packedOrders.length != 0) {
      bytes32 lastPacked = packedOrders[packedOrders.length - 1];
      // Are there are free entries in this segment
      for (uint i = 0; i < NUM_ORDERS_PER_SEGMENT; ++i) {
        uint orderId = uint40(uint(lastPacked >> (i * 64)));
        if (orderId == 0) {
          // Found one, so add to an existing segment
          bytes32 newPacked = lastPacked | (bytes32(_orderId) << (i * 64)) | (bytes32(_quantity) << (i * 64 + 40));
          packedOrders[packedOrders.length - 1] = newPacked;
          pushToEnd = false;
          break;
        }
      }
    }

    if (pushToEnd) {
      bytes32 packedOrder = bytes32(_orderId) | (bytes32(_quantity) << 40);
      packedOrders.push(packedOrder);
    }
  }

  function _addToBook(bool _isBuy, uint _tokenId, uint64 _price, uint24 _quantity) private {
    uint40 orderId = nextOrderId++;
    orderBookIdToMaker[orderId] = msg.sender;
    uint64 price;
    // Price can update if the price level is at capacity
    if (_isBuy) {
      price = _addToBookSide(
        bidValues[_tokenId],
        bids[_tokenId],
        _tokenId,
        _price,
        orderId,
        _quantity,
        -int128(tokenIdInfos[_tokenId].tick)
      );
    } else {
      price = _addToBookSide(
        askValues[_tokenId],
        asks[_tokenId],
        _tokenId,
        _price,
        orderId,
        _quantity,
        int128(tokenIdInfos[_tokenId].tick)
      );
    }
    emit AddedToBook(_isBuy, orderId, _quantity, price);
  }

  function _calcFees(uint _cost) private view returns (uint royalty, uint dev, uint burn) {
    royalty = (_cost * royaltyFee) / 10000;
    dev = (_cost * devFee) / 10000;
    burn = (_cost * burntFee) / 10000;
  }

  function _sendFees(uint _royalty, uint _dev, uint _burn) private {
    if (_royalty > 0) {
      _safeTransferFromUs(royaltyRecipient, _royalty);
    }

    if (_dev > 0) {
      _safeTransferFromUs(devAddr, _dev);
    }

    if (_burn > 0) {
      token.burn(_burn);
    }
  }

  function _find(
    bytes32[] storage packedData,
    uint begin,
    uint end,
    uint value
  ) internal view returns (uint mid, uint offset) {
    while (begin < end) {
      mid = begin + (end - begin) / 2;
      uint packed = uint(packedData[mid]);
      offset = 0;

      for (uint i = 0; i < NUM_ORDERS_PER_SEGMENT; i++) {
        uint40 id = uint40(packed >> (offset * 8));
        if (id == value) {
          return (mid, i); // Return the index where the ID is found
        } else if (id < value) {
          offset += 8; // Move to the next segment
        } else {
          break; // Break if the searched value is smaller, as it's a binary search
        }
      }

      if (offset == NUM_ORDERS_PER_SEGMENT * 8) {
        begin = mid + 1;
      } else {
        end = mid;
      }
    }

    return (type(uint).max, type(uint).max); // ID not found in any segment of the packed data
  }

  function _cancelOrder(
    bytes32[] storage orderBookEntries,
    uint64 _price,
    uint _index,
    uint _offset,
    uint _tombstoneOffset,
    BokkyPooBahsRedBlackTreeLibrary.Tree storage _tree
  ) private {
    bytes32 packed = orderBookEntries[_index];
    uint40 orderId = uint40(uint(packed) >> (_offset * 64));

    address maker = orderBookIdToMaker[orderId];
    if (maker == address(0) || maker != msg.sender) {
      revert NotMaker();
    }

    if (_offset == 0 && packed >> 64 == bytes32(0)) {
      // Remove the entire segment by shifting all other segments to the left. Not very efficient, but this at least only affects the user cancelling
      uint length = orderBookEntries.length;
      for (uint i = _index; i < length - 1; ++i) {
        orderBookEntries[i] = orderBookEntries[i + 1];
      }
      orderBookEntries.pop();
      if (orderBookEntries.length - _tombstoneOffset == 0) {
        // Last one at this price level so trash it
        _tree.remove(_price);
      }
    } else {
      // Just shift orders in the segment
      for (uint i = _offset; i < NUM_ORDERS_PER_SEGMENT - 1; ++i) {
        // Shift the next one into this one
        uint nextSection = uint64(uint(packed) >> ((i + 1) * 64));
        packed = packed & ~(bytes32(uint(0xffffffffffffffff) << (i * 64)));
        packed = packed | (bytes32(nextSection) << (i * 64));
      }

      // Last one set to 0
      packed = packed & ~(bytes32(uint(0xffffffffffffffff) << ((NUM_ORDERS_PER_SEGMENT - 1) * 64)));
      orderBookEntries[_index] = packed;
    }
  }

  function _safeTransferFromUs(address _to, uint _amount) private {
    token.transfer(_to, _amount);
  }

  function _safeTransferNFTsFromUs(address _to, uint _tokenId, uint _amount) private {
    nft.safeTransferFrom(address(this), _to, _tokenId, _amount, "");
  }

  function _safeBatchTransferNFTsFromUs(address _to, uint[] memory _tokenIds, uint[] memory _amounts) private {
    nft.safeBatchTransferFrom(address(this), _to, _tokenIds, _amounts, "");
  }

  function tokensClaimable(uint40[] calldata _orderIds, bool takeAwayFees) external view returns (uint amount) {
    for (uint i = 0; i < _orderIds.length; ++i) {
      amount += brushClaimable[_orderIds[i]];
    }
    if (takeAwayFees) {
      (uint royalty, uint dev, uint burn) = _calcFees(amount);
      amount -= royalty + dev + burn;
    }
  }

  function nftClaimable(uint40[] calldata _orderIds, uint _tokenId) external view returns (uint amount) {
    for (uint i = 0; i < _orderIds.length; ++i) {
      amount += tokenIdsClaimable[_orderIds[i]][_tokenId];
    }
  }

  function getHighestBid(uint _tokenId) public view returns (uint64) {
    return bids[_tokenId].last();
  }

  function getLowestAsk(uint _tokenId) public view returns (uint64) {
    return asks[_tokenId].first();
  }

  function getNode(
    OrderSide _side,
    uint _tokenId,
    uint64 _price
  ) external view returns (BokkyPooBahsRedBlackTreeLibrary.Node memory) {
    if (_side == OrderSide.Buy) {
      return bids[_tokenId].getNode(_price);
    } else {
      return asks[_tokenId].getNode(_price);
    }
  }

  function setMaxOrdersPerPrice(uint16 _maxOrdersPerPrice) external onlyOwner {
    maxOrdersPerPrice = _maxOrdersPerPrice;
  }

  function setTokenIdInfos(uint[] calldata _tokenIds, TokenIdInfo[] calldata _tokenIdInfos) external onlyOwner {
    if (_tokenIds.length != _tokenIdInfos.length) {
      revert LengthMismatch();
    }

    for (uint i = 0; i < _tokenIds.length; ++i) {
      tokenIdInfos[_tokenIds[i]] = _tokenIdInfos[i];
    }

    emit SetTokenIdInfos(_tokenIds, _tokenIdInfos);
  }

  function getTick(uint _tokenId) external view returns (uint) {
    return tokenIdInfos[_tokenId].tick;
  }

  function getMinAmount(uint _tokenId) external view returns (uint) {
    return tokenIdInfos[_tokenId].minQuantity;
  }

  // solhint-disable-next-line no-empty-blocks
  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
