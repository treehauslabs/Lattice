import Foundation

public actor OrderBook {
    private var orders: [String: [SignedOrder]] = [:]
    private var processedNonces: Set<UInt128> = []
    private var cancelledNonces: Set<UInt128> = []
    private var filledAmounts: [UInt128: UInt64] = [:]

    public init() {}

    private func pairKey(source: String, dest: String) -> String {
        "\(source)>\(dest)"
    }

    public func submit(order: SignedOrder) -> Bool {
        guard order.verify() else { return false }
        guard order.order.sourceAmount > 0 && order.order.destAmount > 0 else { return false }
        guard !processedNonces.contains(order.order.nonce) else { return false }
        guard !cancelledNonces.contains(order.order.nonce) else { return false }

        let key = pairKey(source: order.order.sourceChain, dest: order.order.destChain)
        orders[key, default: []].append(order)
        return true
    }

    public func cancel(cancellation: OrderCancellation) -> Bool {
        guard cancellation.verify() else { return false }
        let nonce = cancellation.orderNonce
        cancelledNonces.insert(nonce)
        removeOrder(nonce: nonce)
        filledAmounts.removeValue(forKey: nonce)
        return true
    }

    private func removeOrder(nonce: UInt128) {
        for (key, var list) in orders {
            list.removeAll { $0.order.nonce == nonce }
            orders[key] = list.isEmpty ? nil : list
        }
    }

    private func remaining(_ order: SignedOrder) -> UInt64 {
        order.order.sourceAmount - (filledAmounts[order.order.nonce] ?? 0)
    }

    // GCD for reducing clearing price to lowest terms
    private func gcd(_ a: UInt128, _ b: UInt128) -> UInt128 {
        var x = a, y = b
        while y != 0 { let t = y; y = x % y; x = t }
        return x
    }

    // Sort sellers by ask rate ascending (cheapest first), then fee descending
    private func sortSellers(_ orders: [SignedOrder]) -> [SignedOrder] {
        orders.sorted { a, b in
            // Rate = destAmount/sourceAmount — lower is cheaper (seller asks less per unit sold)
            let lhs = UInt128(a.order.destAmount) &* UInt128(b.order.sourceAmount)
            let rhs = UInt128(b.order.destAmount) &* UInt128(a.order.sourceAmount)
            if lhs != rhs { return lhs < rhs }
            return a.order.fee > b.order.fee
        }
    }

    // Sort buyers by bid rate descending (highest bidder first), then fee descending
    private func sortBuyers(_ orders: [SignedOrder]) -> [SignedOrder] {
        orders.sorted { a, b in
            // Buyer on reverse side: willing to pay sourceAmount for destAmount
            // Rate in forward terms = sourceAmount/destAmount — higher means willing to pay more
            let lhs = UInt128(a.order.sourceAmount) &* UInt128(b.order.destAmount)
            let rhs = UInt128(b.order.sourceAmount) &* UInt128(a.order.destAmount)
            if lhs != rhs { return lhs > rhs }
            return a.order.fee > b.order.fee
        }
    }

    public func findMatches(currentBlockIndex: UInt64) -> [MatchedOrder] {
        // Purge expired orders before matching
        for (key, list) in orders {
            let live = list.filter { $0.order.timelock > currentBlockIndex }
            orders[key] = live.isEmpty ? nil : live
        }

        var matches: [MatchedOrder] = []
        var processedPairs: Set<String> = []

        for pair in Array(orders.keys) {
            if processedPairs.contains(pair) { continue }
            guard let forwards = orders[pair], !forwards.isEmpty else { continue }
            guard let first = forwards.first else { continue }
            let reverse = pairKey(source: first.order.destChain, dest: first.order.sourceChain)
            guard let reverses = orders[reverse], !reverses.isEmpty else { continue }
            processedPairs.insert(pair)
            processedPairs.insert(reverse)

            // Group by timelock — only orders sharing a timelock can match
            var forwardsByTimelock: [UInt64: [SignedOrder]] = [:]
            for o in forwards { forwardsByTimelock[o.order.timelock, default: []].append(o) }
            var reversesByTimelock: [UInt64: [SignedOrder]] = [:]
            for o in reverses { reversesByTimelock[o.order.timelock, default: []].append(o) }

            for (timelock, fwdGroup) in forwardsByTimelock {
                guard let revGroup = reversesByTimelock[timelock] else { continue }

                // Forward orders are sellers of source, buyers of dest
                // Reverse orders are buyers of source (they want dest=source of forward)
                let sellers = sortSellers(fwdGroup).filter { remaining($0) > 0 }
                let buyers = sortBuyers(revGroup).filter { remaining($0) > 0 }
                if sellers.isEmpty || buyers.isEmpty { continue }

                // Collect candidate clearing prices from all order rates
                // Price = how much dest per unit of source (in forward direction)
                // Seller ask: destAmount/sourceAmount (as num/den pair)
                // Buyer bid: sourceAmount/destAmount (buyer's source is forward dest)
                struct PriceLevel { let num: UInt128; let den: UInt128 }
                var candidates: [PriceLevel] = []
                for s in sellers {
                    candidates.append(PriceLevel(num: UInt128(s.order.destAmount), den: UInt128(s.order.sourceAmount)))
                }
                for b in buyers {
                    candidates.append(PriceLevel(num: UInt128(b.order.sourceAmount), den: UInt128(b.order.destAmount)))
                }

                // Find volume-maximizing clearing price
                var bestVolume: UInt128 = 0
                var bestNum: UInt128 = 0
                var bestDen: UInt128 = 1

                for candidate in candidates {
                    // Sell volume: sum of remaining for sellers whose ask <= candidate price
                    var sellVol: UInt128 = 0
                    for s in sellers {
                        // ask = s.destAmount/s.sourceAmount <= candidate.num/candidate.den
                        // i.e. s.destAmount * candidate.den <= candidate.num * s.sourceAmount
                        let ask = UInt128(s.order.destAmount) &* candidate.den
                        let price = candidate.num &* UInt128(s.order.sourceAmount)
                        if ask <= price {
                            sellVol += UInt128(remaining(s))
                        }
                    }

                    // Buy volume in source units: sum of (remaining * candidate.den / candidate.num)
                    // buyer's remaining is in dest units, convert to source units at clearing price
                    var buyVol: UInt128 = 0
                    for b in buyers {
                        // bid = b.sourceAmount/b.destAmount >= candidate.num/candidate.den
                        // i.e. b.sourceAmount * candidate.den >= candidate.num * b.destAmount
                        let bid = UInt128(b.order.sourceAmount) &* candidate.den
                        let price = candidate.num &* UInt128(b.order.destAmount)
                        if bid >= price {
                            // Convert buyer's remaining (in reverse-source = forward-dest) to forward-source units
                            buyVol += UInt128(remaining(b)) &* candidate.den / candidate.num
                        }
                    }

                    let volume = min(sellVol, buyVol)
                    if volume > bestVolume {
                        bestVolume = volume
                        bestNum = candidate.num
                        bestDen = candidate.den
                    }
                }

                if bestVolume == 0 || bestNum == 0 || bestDen == 0 { continue }

                // Reduce to lowest terms
                let g = gcd(bestNum, bestDen)
                let priceNum = bestNum / g
                let priceDen = bestDen / g

                // Generate matches at the clearing price
                // fillAmountA (source units) and fillAmountB = fillAmountA * priceNum / priceDen (dest units)
                let eligibleSellers = sellers.filter {
                    UInt128($0.order.destAmount) &* priceDen <= priceNum &* UInt128($0.order.sourceAmount)
                }
                let eligibleBuyers = buyers.filter {
                    UInt128($0.order.sourceAmount) &* priceDen >= priceNum &* UInt128($0.order.destAmount)
                }

                var si = 0, bi = 0
                var sellerRemaining: UInt64 = eligibleSellers.isEmpty ? 0 : remaining(eligibleSellers[0])
                var buyerSourceRemaining: UInt64 = 0
                if !eligibleBuyers.isEmpty {
                    let buyRem128 = UInt128(remaining(eligibleBuyers[0])) &* priceDen / priceNum
                    buyerSourceRemaining = UInt64(clamping: buyRem128)
                }

                while si < eligibleSellers.count && bi < eligibleBuyers.count {
                    let seller = eligibleSellers[si]
                    let buyer = eligibleBuyers[bi]

                    if seller.order.maker == buyer.order.maker {
                        bi += 1
                        if bi < eligibleBuyers.count {
                            let buyRem128 = UInt128(remaining(eligibleBuyers[bi])) &* priceDen / priceNum
                            buyerSourceRemaining = UInt64(clamping: buyRem128)
                        }
                        continue
                    }

                    if sellerRemaining == 0 {
                        si += 1
                        if si < eligibleSellers.count { sellerRemaining = remaining(eligibleSellers[si]) }
                        continue
                    }
                    if buyerSourceRemaining == 0 {
                        bi += 1
                        if bi < eligibleBuyers.count {
                            let buyRem128 = UInt128(remaining(eligibleBuyers[bi])) &* priceDen / priceNum
                            buyerSourceRemaining = UInt64(clamping: buyRem128)
                        }
                        continue
                    }

                    // fillA in source units, must yield exact integer fillB
                    let rawFillA = min(sellerRemaining, buyerSourceRemaining)
                    // Round down to nearest multiple of priceDen so fillB is exact
                    let fillA: UInt64
                    if priceDen <= UInt128(UInt64.max) {
                        let den64 = UInt64(priceDen)
                        fillA = (rawFillA / den64) * den64
                    } else {
                        fillA = 0
                    }
                    if fillA == 0 {
                        // Remainder too small for an exact fill at this price
                        bi += 1
                        if bi < eligibleBuyers.count {
                            let buyRem128 = UInt128(remaining(eligibleBuyers[bi])) &* priceDen / priceNum
                            buyerSourceRemaining = UInt64(clamping: buyRem128)
                        }
                        continue
                    }
                    let fillB = UInt64(UInt128(fillA) &* priceNum / priceDen)

                    // Verify both rates are satisfied
                    let checkA = UInt128(fillB) &* UInt128(seller.order.sourceAmount)
                    let needA = UInt128(fillA) &* UInt128(seller.order.destAmount)
                    let checkB = UInt128(fillA) &* UInt128(buyer.order.sourceAmount)
                    let needB = UInt128(fillB) &* UInt128(buyer.order.destAmount)
                    guard checkA >= needA && checkB >= needB else {
                        bi += 1
                        if bi < eligibleBuyers.count {
                            let buyRem128 = UInt128(remaining(eligibleBuyers[bi])) &* priceDen / priceNum
                            buyerSourceRemaining = UInt64(clamping: buyRem128)
                        }
                        continue
                    }

                    guard fillB <= remaining(buyer) else {
                        bi += 1
                        if bi < eligibleBuyers.count {
                            let buyRem128 = UInt128(remaining(eligibleBuyers[bi])) &* priceDen / priceNum
                            buyerSourceRemaining = UInt64(clamping: buyRem128)
                        }
                        continue
                    }

                    let hash = CryptoUtils.doubleSha256("\(seller.order.nonce):\(buyer.order.nonce):\(fillA):\(fillB)")
                    let matchNonce = UInt128(hash.prefix(32), radix: 16) ?? 0

                    matches.append(MatchedOrder(
                        orderA: seller, orderB: buyer, nonce: matchNonce,
                        fillAmountA: fillA, fillAmountB: fillB
                    ))

                    filledAmounts[seller.order.nonce, default: 0] += fillA
                    filledAmounts[buyer.order.nonce, default: 0] += fillB

                    sellerRemaining -= fillA
                    buyerSourceRemaining -= fillA
                }
            }
        }

        // Remove fully-filled orders from the book
        for match in matches {
            let nonceA = match.orderA.order.nonce
            let nonceB = match.orderB.order.nonce
            if remaining(match.orderA) == 0 {
                processedNonces.insert(nonceA)
                removeOrder(nonce: nonceA)
                filledAmounts.removeValue(forKey: nonceA)
            }
            if remaining(match.orderB) == 0 {
                processedNonces.insert(nonceB)
                removeOrder(nonce: nonceB)
                filledAmounts.removeValue(forKey: nonceB)
            }
        }

        return matches
    }

    public func pendingCount() -> Int {
        orders.values.reduce(0) { $0 + $1.count }
    }

    public func pendingOrders(sourceChain: String, destChain: String) -> [SignedOrder] {
        orders[pairKey(source: sourceChain, dest: destChain)] ?? []
    }
}
