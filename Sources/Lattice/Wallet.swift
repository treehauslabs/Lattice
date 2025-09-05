//import Foundation
//
//public class Wallet {
//    public let privateKey: String
//    public let publicKey: String
//    public let address: String
//    
//    public init() {
//        let keyPair = CryptoUtils.generateKeyPair()
//        self.privateKey = keyPair.privateKey
//        self.publicKey = keyPair.publicKey
//        self.address = CryptoUtils.createAddress(from: keyPair.publicKey)
//    }
//    
//    public init(privateKey: String) {
//        self.privateKey = privateKey
//        let keyPair = CryptoUtils.generateKeyPair()
//        self.publicKey = keyPair.publicKey
//        self.address = CryptoUtils.createAddress(from: keyPair.publicKey)
//    }
//    
//    public func getBalance(from blockchain: Blockchain) -> Double {
//        return blockchain.getBalance(address: address)
//    }
//    
//    public func createTransaction(to recipient: String, amount: Double, fee: Double = 0.01) -> Transaction? {
//        guard amount > 0, fee >= 0 else {
//            return nil
//        }
//        
//        let transaction = Transaction(from: address, to: recipient, amount: amount, fee: fee)
//        return signTransaction(transaction)
//    }
//    
//    public func signTransaction(_ transaction: Transaction) -> Transaction? {
//        let transactionData = "\(transaction.id)\(transaction.timestamp.timeIntervalSince1970)"
//        
//        guard let signature = CryptoUtils.sign(message: transactionData, privateKeyHex: privateKey) else {
//            return nil
//        }
//        
//        let signedInputs = transaction.inputs.map { input in
//            TransactionInput(
//                transactionId: input.transactionId,
//                outputIndex: input.outputIndex,
//                signature: signature,
//                publicKey: publicKey
//            )
//        }
//        
//        return Transaction(inputs: signedInputs, outputs: transaction.outputs, fee: transaction.fee)
//    }
//    
//    public func verifyTransaction(_ transaction: Transaction) -> Bool {
//        for input in transaction.inputs {
//            let transactionData = "\(transaction.id)\(transaction.timestamp.timeIntervalSince1970)"
//            
//            if !CryptoUtils.verify(message: transactionData, signature: input.signature, publicKeyHex: input.publicKey) {
//                return false
//            }
//        }
//        
//        return true
//    }
//    
//    public func getTransactionHistory(from blockchain: Blockchain) -> [Transaction] {
//        return blockchain.getTransactionHistory(address: address)
//    }
//    
//    public func exportPrivateKey() -> String {
//        return privateKey
//    }
//    
//    public func exportWalletInfo() -> [String: String] {
//        return [
//            "privateKey": privateKey,
//            "publicKey": publicKey,
//            "address": address
//        ]
//    }
//    
//    public static func importWallet(privateKey: String) -> Wallet {
//        return Wallet(privateKey: privateKey)
//    }
//    
//    public static func validateAddress(_ address: String) -> Bool {
//        return address.count >= 26 && address.hasPrefix("1")
//    }
//}
