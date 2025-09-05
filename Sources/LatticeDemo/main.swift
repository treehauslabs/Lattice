//import Foundation
//import Lattice
//
//print("🚀 Lattice Blockchain Demo")
//print("=" * 50)
//
//print("1️⃣ Creating blockchain with difficulty 2...")
//let blockchain = Blockchain(difficulty: 2, miningReward: 50.0)
//
//print("2️⃣ Creating wallets...")
//let alice = Wallet()
//let bob = Wallet()
//let miner = Wallet()
//
//print("Alice's address: \(alice.address)")
//print("Bob's address: \(bob.address)")
//print("Miner's address: \(miner.address)")
//
//print("\n3️⃣ Mining genesis rewards to Alice...")
//let genesis = blockchain.minePendingTransactions(miningRewardAddress: alice.address)
//print("Genesis block mined: \(genesis?.hash.prefix(16) ?? "failed")...")
//
//print("Alice's balance: \(alice.getBalance(from: blockchain)) coins")
//
//print("\n4️⃣ Creating transaction from Alice to Bob...")
//if let transaction = alice.createTransaction(to: bob.address, amount: 20.0, fee: 1.0) {
//    let success = blockchain.addTransaction(transaction)
//    print("Transaction added to mempool: \(success)")
//} else {
//    print("❌ Failed to create transaction")
//}
//
//print("\n5️⃣ Mining pending transactions...")
//let block1 = blockchain.minePendingTransactions(miningRewardAddress: miner.address)
//print("Block 1 mined: \(block1?.hash.prefix(16) ?? "failed")...")
//
//print("\n6️⃣ Final balances:")
//print("Alice: \(alice.getBalance(from: blockchain)) coins")
//print("Bob: \(bob.getBalance(from: blockchain)) coins")
//print("Miner: \(miner.getBalance(from: blockchain)) coins")
//
//print("\n7️⃣ Validating blockchain...")
//let validation = Validator.validateBlockchain(blockchain)
//print("Blockchain is valid: \(validation.isValid)")
//if !validation.isValid {
//    for error in validation.errors {
//        print("❌ \(error)")
//    }
//}
//
//print("\n8️⃣ Blockchain statistics:")
//print("Total blocks: \(blockchain.blocks.count)")
//print("Latest block hash: \(blockchain.latestBlock?.hash.prefix(16) ?? "none")...")
//print("Chain is valid: \(blockchain.isChainValid())")
//
//print("\n✅ Demo completed!")
//
//extension String {
//    static func *(lhs: String, rhs: Int) -> String {
//        return String(repeating: lhs, count: rhs)
//    }
//}
