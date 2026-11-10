import Foundation
import Security
import LocalAuthentication

// Only identifiers and labels go in JSON. Secrets remain in this Mac's Keychain.
enum NotionVault {
    static let service="com.ssuzuki.WorkspaceTabs.notion"
    static func read(_ id:String, legacy:Bool=false, interactive:Bool=true)->String? {
        var query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:legacy ? "com.ssuzuki.LinkViewer.tokens":service,kSecAttrAccount as String:id,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        if !interactive {let context=LAContext();context.interactionNotAllowed=true;query[kSecUseAuthenticationContext as String]=context}
        var result:CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess,let data=result as? Data else{return nil}
        return String(data:data,encoding:.utf8)
    }
    static func write(_ id:String,secret:String)throws {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id]
        let data=Data(secret.utf8)
        let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var item=query;item[kSecValueData as String]=data;item[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added=SecItemAdd(item as CFDictionary,nil)
            guard added == errSecSuccess else{throw LVError(L("PATをキーチェーンに保存できません（\(added)）"))}
        } else if status != errSecSuccess {throw LVError(L("キーチェーンを更新できません（\(status)）"))}
    }
}
enum Storage {
    static var root:URL {FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("WorkspaceTabs")}
    static var icons:URL {root.appendingPathComponent("Icons")}
    static func prepare()throws {try FileManager.default.createDirectory(at:icons,withIntermediateDirectories:true)}
}
struct NotionEdit:Codable,Identifiable {
    var id:UUID {value.id}
    var value:WorkspaceCore.FavoriteLink
    var delete=false
    var failure:String?
    var uncertain=false
}
import WorkspaceCore
struct NotionLibraryState:Codable {
    var enabled=false
    var sources:[LVSource]=[]
    var tokens:[TokenInfo]=[]
    var cache:LinkData?
    var edits:[NotionEdit]=[]
    var migrated=false
    var linkViewerMigrationComplete:Bool?
    var tabSourceID:String?
    var tabTokenID:String?
    var tabDatabaseURL:String?
    var saveTabs=false
    var includePages=true
    var deviceID=UUID().uuidString
    var deviceName=Host.current().localizedName ?? "Mac"
    var tabPageID:String?
    var tabWriteUncertain=false
    var lastTabDigest:String?
}
