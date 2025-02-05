//
//  NotificationService.swift
//  NotificationServiceExtension
//
//  Created by huangfeng on 2018/12/17.
//  Copyright © 2018 Fin. All rights reserved.
//

import UIKit
import UserNotifications
import RealmSwift
import Kingfisher
import MobileCoreServices
import Intents
class NotificationService: UNNotificationServiceExtension {
    
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?
    
    lazy var realm:Realm? = {
        let groupUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.bark")
        let fileUrl = groupUrl?.appendingPathComponent("bark.realm")
        let config = Realm.Configuration(
            fileURL: fileUrl,
            schemaVersion: 13,
            migrationBlock: { migration, oldSchemaVersion in
                // We haven’t migrated anything yet, so oldSchemaVersion == 0
                if (oldSchemaVersion < 1) {
                    // Nothing to do!
                    // Realm will automatically detect new properties and removed properties
                    // And will update the schema on disk automatically
                }
        })

        // Tell Realm to use this new configuration object for the default Realm
        Realm.Configuration.defaultConfiguration = config


        return try? Realm()
    }()
    
    
    /// 自动保存推送
    /// - Parameters:
    ///   - userInfo: 推送参数
    ///   - bestAttemptContentBody: 推送body，如果用户`没有指定要复制的值` ，默认复制 `推送正文`
    fileprivate func autoCopy(_ userInfo: [AnyHashable : Any], defaultCopy  bestAttemptContentBody: String) {
        if userInfo["autocopy"] as? String == "1"
            || userInfo["automaticallycopy"] as? String == "1"{
            if let copy = userInfo["copy"] as? String {
                UIPasteboard.general.string = copy
            }
            else{
                UIPasteboard.general.string = bestAttemptContentBody
            }
        }
    }
    
    
    /// 保存推送
    /// - Parameter userInfo: 推送参数
    /// 如果用户携带了 `isarchive` 参数，则以 `isarchive` 参数值为准
    /// 否则，以用户`应用内设置`为准
    fileprivate func archive(_ userInfo: [AnyHashable : Any]) {
        var isArchive:Bool?
        if let archive = userInfo["isarchive"] as? String{
            isArchive = archive == "1" ? true : false
        }
        if isArchive == nil {
            isArchive = ArchiveSettingManager.shared.isArchive
        }
        let alert = (userInfo["aps"] as? [String:Any])?["alert"] as? [String:Any]
        let title = alert?["title"] as? String
        let body = alert?["body"] as? String
        
        let url = userInfo["url"] as? String
        let group = userInfo["group"] as? String
        
        if (isArchive == true){
            try? realm?.write{
                let message = Message()
                message.title = title
                message.body = body
                message.url = url
                message.group = group
                message.createDate = Date()
                realm?.add(message)
            }
        }
    }
    
    
    /// 下载推送图片
    /// - Parameters:
    ///   - userInfo: 推送参数
    ///   - bestAttemptContent: 推送content
    ///   - complection: 下载图片完毕后的回调函数
    fileprivate func downloadImage(_ imageUrl:String, complection: @escaping (_ imageFileUrl:String?) -> () ) {
        guard let groupUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.bark"),
              let cache = try? ImageCache(name: "shared",cacheDirectoryURL: groupUrl),
              let imageResource = URL(string: imageUrl)
        else {
            complection(nil)
            return
        }
        
        func downloadFinished(){
            let cacheFileUrl = cache.cachePath(forKey: imageResource.cacheKey)
            complection(cacheFileUrl)
        }

        // 先查看图片缓存
        if cache.diskStorage.isCached(forKey: imageResource.cacheKey) {
            downloadFinished()
            return
        }
        
        // 下载图片
        Kingfisher.ImageDownloader.default.downloadImage(with: imageResource, options: nil) { result in
            guard let result = try? result.get() else {
                complection(nil)
                return
            }
            // 缓存图片
            cache.storeToDisk(result.originalData, forKey: imageResource.cacheKey, expiration: StorageExpiration.never) { r in
                downloadFinished()
            }
        }
    }
    
    /// 下载推送图片
    /// - Parameters:
    ///   - userInfo: 推送参数
    ///   - bestAttemptContent: 推送content
    ///   - complection: 下载图片完毕后的回调函数
    fileprivate func setImage(_ userInfo: [AnyHashable : Any], content bestAttemptContent: UNMutableNotificationContent, complection: @escaping () -> () ) {
        
        guard let imageUrl = userInfo["image"] as? String else {
            complection()
            return
        }
        
        func finished(_ imageFileUrl: String?){
            guard let imageFileUrl = imageFileUrl else {
                complection()
                return
            }
            let copyDestUrl = URL(fileURLWithPath: imageFileUrl).appendingPathExtension(".tmp")
            // 将图片缓存复制一份，推送使用完后会自动删除，但图片缓存需要留着以后在历史记录里查看
            try? FileManager.default.copyItem(
                at: URL(fileURLWithPath: imageFileUrl),
                to: copyDestUrl)
            
            if  let attachment  = try? UNNotificationAttachment(
                    identifier: "image",
                    url: copyDestUrl,
                    options: [UNNotificationAttachmentOptionsTypeHintKey : kUTTypePNG]){
                bestAttemptContent.attachments = [ attachment ]
            }
            complection()
        }
        
        downloadImage(imageUrl, complection: finished)
    }
    
    fileprivate func setIcon(_ userInfo: [AnyHashable : Any], content bestAttemptContent: UNMutableNotificationContent, complection: @escaping () -> () ) {
        if #available(iOSApplicationExtension 15.0, *) {
            guard let imageUrl = userInfo["icon"] as? String else {
                complection()
                return
            }
            
            func finished(_ imageFileUrl: String?){
                guard let imageFileUrl = imageFileUrl else {
                    complection()
                    return
                }
                var personNameComponents = PersonNameComponents()
                personNameComponents.nickname = bestAttemptContent.title
                
                let avatar = INImage(imageData: NSData(contentsOfFile: imageFileUrl)! as Data)
                let senderPerson = INPerson(
                    personHandle: INPersonHandle(value: "", type: .unknown),
                    nameComponents: personNameComponents,
                    displayName: personNameComponents.nickname,
                    image: avatar,
                    contactIdentifier: nil,
                    customIdentifier: nil,
                    isMe: false,
                    suggestionType: .none
                )
                let mePerson = INPerson(
                    personHandle: INPersonHandle(value: "", type: .unknown),
                    nameComponents: nil,
                    displayName: nil,
                    image: nil,
                    contactIdentifier: nil,
                    customIdentifier: nil,
                    isMe: true,
                    suggestionType: .none
                )
                
                let intent = INSendMessageIntent(
                    recipients: [mePerson],
                    outgoingMessageType: .outgoingMessageText,
                    content: bestAttemptContent.body,
                    speakableGroupName: INSpeakableString(spokenPhrase: personNameComponents.nickname ?? ""),
                    conversationIdentifier: "sampleConversationIdentifier",
                    serviceName: nil,
                    sender: senderPerson,
                    attachments: nil
                )
                
                intent.setImage(avatar, forParameterNamed: \.sender)
                
                let interaction = INInteraction(intent: intent, response: nil)
                interaction.direction = .incoming
                
                interaction.donate(completion: nil)
                
                do {
                    let content = try self.bestAttemptContent!.updating(from: intent) as! UNMutableNotificationContent
                    self.bestAttemptContent = content
                } catch {
                    // Handle error
                }
                
                complection()
            }
            
            downloadImage(imageUrl, complection: finished)
        }
        else{
            complection()
        }
    }
    
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        
        if let bestAttemptContent = bestAttemptContent {
            let userInfo = bestAttemptContent.userInfo
            
            // 自动复制
            autoCopy(userInfo, defaultCopy: bestAttemptContent.body)
            // 保存推送
            archive(userInfo)
            // 设置推送图标
            setIcon(userInfo, content: self.bestAttemptContent!) {
                // 设置推送图片
                self.setImage(userInfo, content: self.bestAttemptContent!) {
                    contentHandler(self.bestAttemptContent!)
                }
            }
            
        }
        else{
            contentHandler(bestAttemptContent!)
        }
    }
}
