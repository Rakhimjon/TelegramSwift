//
//  ChatMessageItem.swift
//  Telegram-Mac
//
//  Created by keepcoder on 16/09/16.
//  Copyright © 2016 Telegram. All rights reserved.
//

import Cocoa
import TGUIKit
import TelegramCoreMac
import PostboxMac
import SwiftSignalKitMac
class ChatMessageItem: ChatRowItem {
    public private(set) var messageText:NSAttributedString
    public private(set) var textLayout:TextViewLayout
    
    override var selectableLayout:[TextViewLayout] {
        return [textLayout]
    }
    
    override func tableViewDidUpdated() {
        webpageLayout?.table = self.table
    }
    
    override var isSharable: Bool {
        if let webpage = webpageLayout {
            if webpage.content.type == "proxy" {
                return true
            }
        }
        return super.isSharable
    }
    
    override var isBubbleFullFilled: Bool {
        return containsBigEmoji || super.isBubbleFullFilled
    }
    
    override var isStateOverlayLayout: Bool {
        return containsBigEmoji && renderType == .bubble || super.isStateOverlayLayout
    }
    
    override var bubbleContentInset: CGFloat {
        return containsBigEmoji && renderType == .bubble ? 0 : super.bubbleContentInset
    }
    
    override var defaultContentTopOffset: CGFloat {
        if isBubbled && !hasBubble {
            return 2
        }
        return super.defaultContentTopOffset
    }
    
    override var hasBubble: Bool {
        get {
            if containsBigEmoji {
                return false
            } else {
                return super.hasBubble
            }
        }
        set {
            super.hasBubble = newValue
        }
    }
    
    let containsBigEmoji: Bool
    
    var unsupported: Bool {

        if let message = message, message.text.isEmpty && (message.media.isEmpty || message.media.first is TelegramMediaUnsupported) {
            return message.inlinePeer == nil
        } else {
            return false
        }
    }
    
    var actionButtonText: String? {
        if let webpage = webpageLayout, !webpage.hasInstantPage {
            let link = inApp(for: webpage.content.url.nsstring, context: context, openInfo: chatInteraction.openInfo)
            switch link {
            case let .followResolvedName(_, _, postId, _, _, _):
                if let postId = postId, postId > 0 {
                    return L10n.chatMessageActionShowMessage
                }
            default:
                break
            }
            if webpage.wallpaper != nil {
                return L10n.chatViewBackground
            }
        }
        
        if unsupported {
            return L10n.chatUnsupportedUpdatedApp
        }
        
        return nil
    }
    
    override var isEditMarkVisible: Bool {
        if containsBigEmoji {
            return false
        } else {
            return super.isEditMarkVisible
        }
    }
    
    func invokeAction() {
        if let webpage = webpageLayout {
            let link = inApp(for: webpage.content.url.nsstring, context: context, openInfo: chatInteraction.openInfo)
            execute(inapp: link)
        } else if unsupported {
            #if APP_STORE
            execute(inapp: inAppLink.external(link: "https://itunes.apple.com/us/app/telegram/id747648890", false))
            #else
            (NSApp.delegate as? AppDelegate)?.checkForUpdates("")
            #endif
        }
    }
    
    let wpPresentation: WPLayoutPresentation
    
    var webpageLayout:WPLayout?
    
    override init(_ initialSize:NSSize, _ chatInteraction:ChatInteraction,_ context: AccountContext, _ entry: ChatHistoryEntry, _ downloadSettings: AutomaticMediaDownloadSettings) {
        
         if let message = entry.message {
            
            let isIncoming: Bool = message.isIncoming(context.account, entry.renderType == .bubble)

            
            let messageAttr:NSMutableAttributedString
            if message.inlinePeer == nil, message.text.isEmpty && (message.media.isEmpty || message.media.first is TelegramMediaUnsupported) {
                let attr = NSMutableAttributedString()
                _ = attr.append(string: L10n.chatMessageUnsupportedNew, color: theme.chat.textColor(isIncoming, entry.renderType == .bubble), font: .code(theme.fontSize))
                messageAttr = attr
            } else {
                messageAttr = ChatMessageItem.applyMessageEntities(with: message.attributes, for: message.text, context: context, fontSize: theme.fontSize, openInfo:chatInteraction.openInfo, botCommand:chatInteraction.sendPlainText, hashtag: context.sharedContext.bindings.globalSearch, applyProxy: chatInteraction.applyProxy, textColor: theme.chat.textColor(isIncoming, entry.renderType == .bubble), linkColor: theme.chat.linkColor(isIncoming, entry.renderType == .bubble), monospacedPre: theme.chat.monospacedPreColor(isIncoming, entry.renderType == .bubble), monospacedCode: theme.chat.monospacedCodeColor(isIncoming, entry.renderType == .bubble)).mutableCopy() as! NSMutableAttributedString

                messageAttr.fixUndefinedEmojies()
                
                
                var formatting: Bool = messageAttr.length > 0 
                var index:Int = 0
                while formatting {
                    var effectiveRange:NSRange = NSMakeRange(NSNotFound, 0)
                    if let _ = messageAttr.attribute(.preformattedPre, at: index, effectiveRange: &effectiveRange), effectiveRange.location != NSNotFound {
                        
                        let beforeAndAfter:(Int)->Bool = { index -> Bool in
                            let prefix:String = messageAttr.string.nsstring.substring(with: NSMakeRange(index, 1))
                            let whiteSpaceRange = prefix.rangeOfCharacter(from: NSCharacterSet.whitespaces)
                            var increment: Bool = false
                            if let _ = whiteSpaceRange {
                                messageAttr.replaceCharacters(in: NSMakeRange(index, 1), with: "\n")
                            } else if prefix != "\n" {
                                messageAttr.insert(.initialize(string: "\n"), at: index)
                                increment = true
                            }
                            return increment
                        }
                        
                        if effectiveRange.min > 0 {
                            let increment = beforeAndAfter(effectiveRange.min)
                            if increment {
                                effectiveRange = NSMakeRange(effectiveRange.location, effectiveRange.length + 1)
                            }
                        }
                        if effectiveRange.max < messageAttr.length - 1 {
                            let increment = beforeAndAfter(effectiveRange.max)
                            if increment {
                                effectiveRange = NSMakeRange(effectiveRange.location, effectiveRange.length + 1)
                            }
                        }
                    }
                    
                    if effectiveRange.location != NSNotFound {
                        index += effectiveRange.length
                    } else {
                        index += 1
                    }
                    
                    formatting = index < messageAttr.length
                }
                
//                if message.isScam {
//                    _ = messageAttr.append(string: "\n\n")
//                    _ = messageAttr.append(string: L10n.chatScamWarning, color: theme.chat.textColor(isIncoming, entry.renderType == .bubble), font: .normal(theme.fontSize))
//                }
            }
            
            
            
            
            let copy = messageAttr.mutableCopy() as! NSMutableAttributedString
            
            if let peer = message.peers[message.id.peerId] {
                if peer is TelegramSecretChat {
                    copy.detectLinks(type: .Links, context: context, color: theme.chat.linkColor(isIncoming, entry.renderType == .bubble))
                }
            }

            let containsBigEmoji: Bool
            if message.media.first == nil, bigEmojiMessage(context.sharedContext, message: message) {
                switch copy.string.glyphCount {
                case 1:
                    copy.addAttribute(.font, value: NSFont.normal(theme.fontSize * 5), range: copy.range)
                    containsBigEmoji = true
                case 2:
                    copy.addAttribute(.font, value: NSFont.normal(theme.fontSize * 4), range: copy.range)
                    containsBigEmoji = true
                case 3:
                    copy.addAttribute(.font, value: NSFont.normal(theme.fontSize * 3), range: copy.range)
                    containsBigEmoji = true
                default:
                    containsBigEmoji = false
                }
            } else {
                containsBigEmoji = false
            }
            
            self.containsBigEmoji = containsBigEmoji
           
            self.messageText = copy
           
            
            textLayout = TextViewLayout(self.messageText, selectText: theme.chat.selectText(isIncoming, entry.renderType == .bubble), strokeLinks: entry.renderType == .bubble && !containsBigEmoji, alwaysStaticItems: true, disableTooltips: false)
            textLayout.mayBlocked = entry.renderType != .bubble
            
            if let highlightFoundText = entry.additionalData?.highlightFoundText {
                if highlightFoundText.isMessage {
                    if let range = rangeOfSearch(highlightFoundText.query, in: copy.string) {
                        textLayout.additionalSelections = [TextSelectedRange(range: range, color: theme.colors.blueIcon.withAlphaComponent(0.5), def: false)]
                    }
                } else {
                    var additionalSelections:[TextSelectedRange] = []
                    let string = copy.string.lowercased().nsstring
                    var searchRange = NSMakeRange(0, string.length)
                    var foundRange:NSRange = NSMakeRange(NSNotFound, 0)
                    while (searchRange.location < string.length) {
                        searchRange.length = string.length - searchRange.location
                        foundRange = string.range(of: highlightFoundText.query.lowercased(), options: [], range: searchRange) 
                        if (foundRange.location != NSNotFound) {
                            additionalSelections.append(TextSelectedRange(range: foundRange, color: theme.colors.grayIcon.withAlphaComponent(0.5), def: false))
                            searchRange.location = foundRange.location+foundRange.length;
                        } else {
                            break
                        }
                    }
                    textLayout.additionalSelections = additionalSelections
                }
                
            }
            
            if let range = selectManager.find(entry.stableId) {
                textLayout.selectedRange.range = range
            }
            
            
            var media = message.media.first
            if let game = media as? TelegramMediaGame {
                media = TelegramMediaWebpage(webpageId: MediaId(namespace: 0, id: 0), content: TelegramMediaWebpageContent.Loaded(TelegramMediaWebpageLoadedContent(url: "", displayUrl: "", hash: 0, type: "photo", websiteName: game.name, title: game.name, text: game.description, embedUrl: nil, embedType: nil, embedSize: nil, duration: nil, author: nil, image: game.image, file: game.file, instantPage: nil)))
            }
            
            self.wpPresentation = WPLayoutPresentation(text: theme.chat.textColor(isIncoming, entry.renderType == .bubble), activity: theme.chat.webPreviewActivity(isIncoming, entry.renderType == .bubble), link: theme.chat.linkColor(isIncoming, entry.renderType == .bubble), selectText: theme.chat.selectText(isIncoming, entry.renderType == .bubble), ivIcon: theme.chat.instantPageIcon(isIncoming, entry.renderType == .bubble), renderType: entry.renderType)

            
            if let webpage = media as? TelegramMediaWebpage {
                switch webpage.content {
                case let .Loaded(content):
                    var forceArticle: Bool = false
                    if let instantPage = content.instantPage {
                        if instantPage.blocks.count == 3 {
                            switch instantPage.blocks[2] {
                            case .collage, .slideshow:
                                forceArticle = true
                            default:
                                break
                            }
                        }
                    }
                    if content.type == "telegram_background" {
                        forceArticle = true
                    }
                    if content.file == nil || forceArticle {
                        webpageLayout = WPArticleLayout(with: content, context: context, chatInteraction: chatInteraction, parent:message, fontSize: theme.fontSize, presentation: wpPresentation, approximateSynchronousValue: Thread.isMainThread, downloadSettings: downloadSettings, autoplayMedia: entry.autoplayMedia)
                    } else {
                        webpageLayout = WPMediaLayout(with: content, context: context, chatInteraction: chatInteraction, parent:message, fontSize: theme.fontSize, presentation: wpPresentation, approximateSynchronousValue: Thread.isMainThread, downloadSettings: downloadSettings, autoplayMedia: entry.autoplayMedia)
                    }
                default:
                    break
                }
            }
            
            super.init(initialSize, chatInteraction, context, entry, downloadSettings)
            
            
            (webpageLayout as? WPMediaLayout)?.parameters?.showMedia = { [weak self] message in
                if let webpage = message.media.first as? TelegramMediaWebpage {
                    switch webpage.content {
                    case let .Loaded(content):
                        if content.embedType == "iframe" && content.type != kBotInlineTypeGif {
                            showModal(with: WebpageModalController(content: content, context: context), for: mainWindow)
                            return
                        }
                    default:
                        break
                    }
                }
                showChatGallery(context: context, message: message, self?.table, (self?.webpageLayout as? WPMediaLayout)?.parameters, type: .alone)
            }
            
            let interactions = globalLinkExecutor
            interactions.copy = {
                selectManager.copy(selectManager)
                return !selectManager.isEmpty
            }
            interactions.menuItems = { [weak self] type in
                var items:[ContextMenuItem] = []
                if let strongSelf = self, let layout = self?.textLayout {
                    
                    let text: String
                    if let type = type {
                        text = copyContextText(from: type)
                    } else {
                        text = layout.selectedRange.hasSelectText ? tr(L10n.chatCopySelectedText) : tr(L10n.textCopy)
                    }
                    
                    
                    items.append(ContextMenuItem(text, handler: { [weak strongSelf] in
                        let result = strongSelf?.textLayout.interactions.copy?()
                        if let result = result, let strongSelf = strongSelf, !result {
                            if strongSelf.textLayout.selectedRange.hasSelectText {
                                let pb = NSPasteboard.general
                                pb.declareTypes([.string], owner: strongSelf)
                                var effectiveRange = strongSelf.textLayout.selectedRange.range
                                
                                let selectedText = strongSelf.textLayout.attributedString.attributedSubstring(from: strongSelf.textLayout.selectedRange.range).string
                                
                                let attribute = strongSelf.textLayout.attributedString.attribute(NSAttributedString.Key.link, at: strongSelf.textLayout.selectedRange.range.location, effectiveRange: &effectiveRange)
                                
                                if let attribute = attribute as? inAppLink {
                                    pb.setString(attribute.link, forType: .string)
                                } else {
                                    pb.setString(selectedText, forType: .string)
                                }
                            }
                            
                        }
                    }))
                    
                    if strongSelf.textLayout.selectedRange.hasSelectText {
                        var effectiveRange: NSRange = NSMakeRange(NSNotFound, 0)
                        if let _ = strongSelf.textLayout.attributedString.attribute(.preformattedPre, at: strongSelf.textLayout.selectedRange.range.location, effectiveRange: &effectiveRange) {
                            let blockText = strongSelf.textLayout.attributedString.attributedSubstring(from: effectiveRange).string
                            items.append(ContextMenuItem(tr(L10n.chatContextCopyBlock), handler: {
                                copyToClipboard(blockText)
                            }))
                        }
                    }
                    
                    
                    return strongSelf.menuItems(in: NSZeroPoint) |> map { basic in
                        var basic = basic
                        if basic.count > 1 {
                            basic.remove(at: 1)
                            basic.insert(contentsOf: items, at: 1)
                        }
                        
                        return basic
                    }
                }
                return .complete()
            }
            
            textLayout.interactions = interactions
            
            return
        }
        
        fatalError("entry has not message")
    }
    
    override var identifier: String {
        if webpageLayout == nil {
            return super.identifier
        } else {
            return super.identifier + "\(stableId)"
        }
    }
    
    
    override var isFixedRightPosition: Bool {
        if containsBigEmoji {
            return true
        }
        if let webpageLayout = webpageLayout {
            if let webpageLayout = webpageLayout as? WPArticleLayout, let textLayout = webpageLayout.textLayout {
                if textLayout.lines.count > 1, let line = textLayout.lines.last, line.frame.width < contentSize.width - (rightSize.width + insetBetweenContentAndDate) {
                    return true
                }
            }
            return super.isFixedRightPosition
        }
        
        if textLayout.lines.count > 1, let line = textLayout.lines.last, line.frame.width < contentSize.width - (rightSize.width + insetBetweenContentAndDate) {
            return true
        }
        return super.isForceRightLine
    }
    
    override var additionalLineForDateInBubbleState: CGFloat? {
        if containsBigEmoji {
            return rightSize.height + 3
        }
        if isForceRightLine {
            return rightSize.height
        }
       
        if let webpageLayout = webpageLayout {
            if let webpageLayout = webpageLayout as? WPArticleLayout {
                if let textLayout = webpageLayout.textLayout {
                    if webpageLayout.hasInstantPage {
                        return rightSize.height
                    }
                    if textLayout.lines.count > 1, let line = textLayout.lines.last, line.frame.width > realContentSize.width - (rightSize.width + insetBetweenContentAndDate) {
                        return rightSize.height
                    }
                    if let _ = webpageLayout.imageSize, webpageLayout.isFullImageSize || textLayout.layoutSize.height - 10 <= webpageLayout.contrainedImageSize.height {
                        return rightSize.height
                    }
                    if actionButtonText != nil {
                        return rightSize.height
                    }
                    if webpageLayout.groupLayout != nil {
                        return rightSize.height
                    }
                } else {
                    return rightSize.height
                }
                
                
            } else if webpageLayout is WPMediaLayout {
                return rightSize.height
            }
            return nil
        }
        
        if textLayout.lines.count == 1 {
            if contentOffset.x + textLayout.layoutSize.width - (rightSize.width + insetBetweenContentAndDate) > width {
                return rightSize.height
            }
        } else if let line = textLayout.lines.last, line.frame.width > realContentSize.width - (rightSize.width + insetBetweenContentAndDate) {
            return rightSize.height
        }
        return nil
    }
    
    override func makeContentSize(_ width: CGFloat) -> NSSize {
        let size:NSSize = super.makeContentSize(width)
     
        webpageLayout?.measure(width: min(width, 380))
        
        let textBlockWidth: CGFloat = isBubbled ? max((webpageLayout?.size.width ?? width), min(240, width)) : width
        
        textLayout.measure(width: textBlockWidth, isBigEmoji: containsBigEmoji)

        
        var contentSize = NSMakeSize(max(webpageLayout?.contentRect.width ?? 0, textLayout.layoutSize.width), size.height + textLayout.layoutSize.height)
        
        if let webpageLayout = webpageLayout {
            contentSize.height += webpageLayout.size.height + defaultContentInnerInset
            contentSize.width = max(webpageLayout.size.width, contentSize.width)
            
        }
        if let _ = actionButtonText {
            contentSize.height += 36
        }
        
        return contentSize
    }
    
    
    override var instantlyResize: Bool {
        return true
    }
    
    override var bubbleFrame: NSRect {
        var frame = super.bubbleFrame
        
        
        if isBubbleFullFilled {
            frame.size.width = contentSize.width + additionBubbleInset
            return frame
        }
        
        if replyMarkupModel != nil, webpageLayout == nil, textLayout.layoutSize.width < 200 {
            frame.size.width = max(blockWidth, frame.width)
        }
        return frame
    }
    
   
    
    override func menuItems(in location: NSPoint) -> Signal<[ContextMenuItem], NoError> {
        var items = super.menuItems(in: location)
        let text = messageText.string
        
        let context = self.context
        
        var media: Media? =  webpageLayout?.content.file ?? webpageLayout?.content.image
        
        if let groupLayout = (webpageLayout as? WPArticleLayout)?.groupLayout {
            if let message = groupLayout.message(at: location) {
                media = message.media.first
            }
        }
        
        if let file = media as? TelegramMediaFile, let message = message {
            items = items |> mapToSignal { items -> Signal<[ContextMenuItem], NoError> in
                var items = items
                return context.account.postbox.mediaBox.resourceData(file.resource) |> deliverOnMainQueue |> mapToSignal { data in
                    if data.complete {
                        items.append(ContextMenuItem(L10n.contextCopyMedia, handler: {
                            saveAs(file, account: context.account)
                        }))
                    }
                    
                    if file.isSticker, let fileId = file.id {
                        return context.account.postbox.transaction { transaction -> [ContextMenuItem] in
                            let saved = getIsStickerSaved(transaction: transaction, fileId: fileId)
                            items.append(ContextMenuItem( !saved ? L10n.chatContextAddFavoriteSticker : L10n.chatContextRemoveFavoriteSticker, handler: {
                                
                                if !saved {
                                    _ = addSavedSticker(postbox: context.account.postbox, network: context.account.network, file: file).start()
                                } else {
                                    _ = removeSavedSticker(postbox: context.account.postbox, mediaId: fileId).start()
                                }
                            }))
                            
                            return items
                        }
                    } else if file.isVideo && file.isAnimated {
                        items.append(ContextMenuItem(L10n.messageContextSaveGif, handler: {
                            let _ = addSavedGif(postbox: context.account.postbox, fileReference: FileMediaReference.message(message: MessageReference(message), media: file)).start()
                        }))
                    }
                    return .single(items)
                }
            }
        } else if let image = media as? TelegramMediaImage {
            items = items |> mapToSignal { items -> Signal<[ContextMenuItem], NoError> in
                var items = items
                if let resource = image.representations.last?.resource {
                    return context.account.postbox.mediaBox.resourceData(resource) |> take(1) |> deliverOnMainQueue |> map { data in
                        if data.complete {
                            items.append(ContextMenuItem(L10n.galleryContextCopyToClipboard, handler: {
                                if let path = link(path: data.path, ext: "jpg") {
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.writeObjects([NSURL(fileURLWithPath: path)])
                                }
                            }))
                            items.append(ContextMenuItem(L10n.contextCopyMedia, handler: {
                                savePanel(file: data.path, ext: "jpg", for: mainWindow)
                            }))
                        }
                        return items
                    }
                } else {
                    return .single(items)
                }
            }
        }

        
        return items |> deliverOnMainQueue |> map { [weak self] items in
            var items = items
            
            var needCopy: Bool = true
            for i in 0 ..< items.count {
                if items[i].title == tr(L10n.messageContextCopyMessageLink1) || items[i].title == tr(L10n.textCopy) {
                    needCopy = false
                }
            }
            if needCopy {

            }
            
            
            if let view = self?.view as? ChatRowView, let textView = view.selectableTextViews.first, let window = textView.window, needCopy {
                let point = textView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if let layout = textView.layout {
                    if let (link, _, range, _) = layout.link(at: point) {
                        var text:String = layout.attributedString.string.nsstring.substring(with: range)
                        if let link = link as? inAppLink {
                            if case let .external(link, _) = link {
                                text = link
                            }
                        }
                        
                        for i in 0 ..< items.count {
                            if items[i].title == tr(L10n.messageContextCopyMessageLink1) {
                                items.remove(at: i)
                                break
                            }
                        }
                        
                        items.insert(ContextMenuItem(tr(L10n.messageContextCopyMessageLink1), handler: {
                            copyToClipboard(text)
                        }), at: min(1, items.count))
                        
                      
                    }
                }
            }
            if let content = self?.webpageLayout?.content, content.type == "proxy" {
                items.insert(ContextMenuItem(L10n.chatCopyProxyConfiguration, handler: {
                    copyToClipboard(content.url)
                }), at: items.isEmpty ? 0 : 1)
            }
            
            return items
        }
    }
    
    override func viewClass() -> AnyClass {
        return ChatMessageView.self
    }
    
    static func applyMessageEntities(with attributes:[MessageAttribute], for text:String, context: AccountContext, fontSize: CGFloat, openInfo:@escaping (PeerId, Bool, MessageId?, ChatInitialAction?)->Void, botCommand:@escaping (String)->Void, hashtag:@escaping (String)->Void, applyProxy:@escaping (ProxyServerSettings)->Void, textColor: NSColor = theme.colors.text, linkColor: NSColor = theme.colors.link, monospacedPre:NSColor = theme.colors.monospacedPre, monospacedCode: NSColor = theme.colors.monospacedCode ) -> NSAttributedString {
        var entities: TextEntitiesMessageAttribute?
        for attribute in attributes {
            if let attribute = attribute as? TextEntitiesMessageAttribute {
                entities = attribute
                break
            }
        }
        
        
        let string = NSMutableAttributedString(string: text, attributes: [NSAttributedString.Key.font: NSFont.normal(fontSize), NSAttributedString.Key.foregroundColor: textColor])
        if let entities = entities {
            var nsString: NSString?
            for entity in entities.entities {
                let range = string.trimRange(NSRange(location: entity.range.lowerBound, length: entity.range.upperBound - entity.range.lowerBound))

                switch entity.type {
                case .Url:
                    string.addAttribute(NSAttributedString.Key.foregroundColor, value: linkColor, range: range)
                    if nsString == nil {
                        nsString = text as NSString
                    }
                    let link = inApp(for:nsString!.substring(with: range) as NSString, context:context, openInfo:openInfo, applyProxy: applyProxy)
                    string.addAttribute(NSAttributedString.Key.link, value: link, range: range)
                case .Email:
                    string.addAttribute(NSAttributedString.Key.foregroundColor, value: linkColor, range: range)
                    if nsString == nil {
                        nsString = text as NSString
                    }
                    string.addAttribute(NSAttributedString.Key.link, value: inAppLink.external(link: "mailto:\(nsString!.substring(with: range))", false), range: range)
                case let .TextUrl(url):
                    string.addAttribute(NSAttributedString.Key.foregroundColor, value: linkColor, range: range)
                    if nsString == nil {
                        nsString = text as NSString
                    }
                    
                    string.addAttribute(NSAttributedString.Key.link, value: inApp(for: url as NSString, context: context, openInfo: openInfo, hashtag: hashtag, command: botCommand,  applyProxy: applyProxy, confirm: true), range: range)
                case .Bold:
                    string.addAttribute(NSAttributedString.Key.font, value: NSFont.bold(fontSize), range: range)
                case .Italic:
                    string.addAttribute(NSAttributedString.Key.font, value: NSFontManager.shared.convert(.normal(fontSize), toHaveTrait: .italicFontMask), range: range)
                case .Mention:
                    string.addAttribute(NSAttributedString.Key.foregroundColor, value: linkColor, range: range)
                    if nsString == nil {
                        nsString = text as NSString
                    }
                    string.addAttribute(NSAttributedString.Key.link, value: inAppLink.followResolvedName(link: nsString!.substring(with: range), username: nsString!.substring(with: range), postId:nil, context:context, action:nil, callback: openInfo), range: range)
                case let .TextMention(peerId):
                    string.addAttribute(NSAttributedString.Key.foregroundColor, value: linkColor, range: range)
                    string.addAttribute(NSAttributedString.Key.link, value: inAppLink.peerInfo(link: "", peerId: peerId, action:nil, openChat: false, postId: nil, callback: openInfo), range: range)
                case .BotCommand:
                    string.addAttribute(NSAttributedString.Key.foregroundColor, value: textColor, range: range)
                    if nsString == nil {
                        nsString = text as NSString
                    }
                    string.addAttribute(NSAttributedString.Key.foregroundColor, value: linkColor, range: range)
                    string.addAttribute(NSAttributedString.Key.link, value: inAppLink.botCommand(nsString!.substring(with: range), botCommand), range: range)
                case .Code:
                    string.addAttribute(.preformattedCode, value: 4.0, range: range)
                    string.addAttribute(NSAttributedString.Key.font, value: NSFont.code(fontSize), range: range)
                    string.addAttribute(NSAttributedString.Key.foregroundColor, value: monospacedCode, range: range)
                    string.addAttribute(NSAttributedString.Key.link, value: inAppLink.code(text.nsstring.substring(with: range), {  link in
                        copyToClipboard(link)
                        context.sharedContext.bindings.showControllerToaster(ControllerToaster(text: L10n.shareLinkCopied), true)
                    }), range: range)
                case  .Pre:
                    string.addAttribute(.preformattedPre, value: 4.0, range: range)
                    string.addAttribute(NSAttributedString.Key.font, value: NSFont.code(fontSize), range: range)
                    string.addAttribute(NSAttributedString.Key.foregroundColor, value: monospacedPre, range: range)
                case .Hashtag:
                    string.addAttribute(NSAttributedString.Key.foregroundColor, value: linkColor, range: range)
                    if nsString == nil {
                        nsString = text as NSString
                    }
                    string.addAttribute(NSAttributedString.Key.link, value: inAppLink.hashtag(nsString!.substring(with: range), hashtag), range: range)
                    break
                default:
                    break
                }
            }
            
        }
        return string.copy() as! NSAttributedString
    }
}
