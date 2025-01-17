//
//  ChatController.swift
//  Telegram-Mac
//
//  Created by keepcoder on 08/09/16.
//  Copyright © 2016 Telegram. All rights reserved.
//

import Cocoa
import TGUIKit
import TelegramCoreMac
import PostboxMac
import SwiftSignalKitMac


extension ChatHistoryLocation {
    var isAtUpperBound: Bool {
        switch self {
        case .Navigation(index: .upperBound, anchorIndex: .upperBound, count: _, side: _):
            return true
        case .Scroll(index: .upperBound, anchorIndex: .upperBound, sourceIndex: _, scrollPosition: _, count: _, animated: _):
            return true
        default:
            return false
        }
    }

}


private var temporaryTouchBar: Any?


struct ChatWrapperEntry : Comparable, Identifiable {
    let appearance: AppearanceWrapperEntry<ChatHistoryEntry>
    let automaticDownload: AutomaticMediaDownloadSettings
    
    var stableId: AnyHashable {
        return appearance.entry.stableId
    }
    
    var entry: ChatHistoryEntry {
        return appearance.entry
    }
}

func ==(lhs:ChatWrapperEntry, rhs: ChatWrapperEntry) -> Bool {
    return lhs.appearance == rhs.appearance && lhs.automaticDownload == rhs.automaticDownload
}
func <(lhs:ChatWrapperEntry, rhs: ChatWrapperEntry) -> Bool {
    return lhs.appearance.entry < rhs.appearance.entry
}


final class ChatHistoryView {
    let originalView: MessageHistoryView?
    let filteredEntries: [ChatWrapperEntry]
    
    init(originalView:MessageHistoryView?, filteredEntries: [ChatWrapperEntry]) {
        self.originalView = originalView
        self.filteredEntries = filteredEntries
    }
    
    deinit {
        var bp:Int = 0
        bp += 1
    }
}

enum ChatControllerViewState {
    case visible
    case progress
    //case IsNotAccessible
}

final class ChatHistoryState : Equatable {
    let isDownOfHistory:Bool
    fileprivate let replyStack:[MessageId]
    init (isDownOfHistory:Bool = true, replyStack:[MessageId] = []) {
        self.isDownOfHistory = isDownOfHistory
        self.replyStack = replyStack
    }
    
    func withUpdatedStateOfHistory(_ isDownOfHistory:Bool) -> ChatHistoryState {
        return ChatHistoryState(isDownOfHistory: isDownOfHistory, replyStack: self.replyStack)
    }
    
    func withAddingReply(_ messageId:MessageId) -> ChatHistoryState {
        var stack = replyStack
        stack.append(messageId)
        return ChatHistoryState(isDownOfHistory: isDownOfHistory, replyStack: stack)
    }
    
    func withClearReplies() -> ChatHistoryState {
        return ChatHistoryState(isDownOfHistory: isDownOfHistory, replyStack: [])
    }
    
    func reply() -> MessageId? {
        return replyStack.last
    }
    
    func withRemovingReplies(max: MessageId) -> ChatHistoryState {
        var copy = replyStack
        for i in stride(from: replyStack.count - 1, to: -1, by: -1) {
            if replyStack[i] <= max {
                copy.remove(at: i)
            }
        }
        return ChatHistoryState(isDownOfHistory: isDownOfHistory, replyStack: copy)
    }
}

func ==(lhs:ChatHistoryState, rhs:ChatHistoryState) -> Bool {
    return lhs.isDownOfHistory == rhs.isDownOfHistory && lhs.replyStack == rhs.replyStack
}


class ChatControllerView : View, ChatInputDelegate {
    
    let tableView:TableView
    let inputView:ChatInputView
    let inputContextHelper:InputContextHelper
    private(set) var state:ChatControllerViewState = .visible
    private var searchInteractions:ChatSearchInteractions!
    private let scroller:ChatNavigateScroller
    private var mentions:ChatNavigationMention?
    private var progressView:ProgressIndicator?
    private let header:ChatHeaderController
    private var historyState:ChatHistoryState?
    private let chatInteraction: ChatInteraction
    var headerState: ChatHeaderState {
        return header.state
    }
    
    deinit {
        var bp:Int = 0
        bp += 1
    }
    
    
    
    required init(frame frameRect: NSRect, chatInteraction:ChatInteraction) {
        self.chatInteraction = chatInteraction
        header = ChatHeaderController(chatInteraction)
        scroller = ChatNavigateScroller(chatInteraction.context, chatInteraction.chatLocation)
        inputContextHelper = InputContextHelper(chatInteraction: chatInteraction)
        tableView = TableView(frame:NSMakeRect(0,0,frameRect.width,frameRect.height - 50), isFlipped:false)
        inputView = ChatInputView(frame: NSMakeRect(0,tableView.frame.maxY, frameRect.width,50), chatInteraction: chatInteraction)
        //inputView.autoresizingMask = [.width]
        super.init(frame: frameRect)
        addSubview(tableView)
        addSubview(inputView)
        inputView.delegate = self
        self.autoresizesSubviews = false
        tableView.autoresizingMask = []
        scroller.set(handler:{ control in
            chatInteraction.scrollToLatest(false)
        }, for: .Click)
        scroller.forceHide()
        tableView.addSubview(scroller)
        
        let context = chatInteraction.context
        

        searchInteractions = ChatSearchInteractions(jump: { message in
            chatInteraction.focusMessageId(nil, message.id, .center(id: 0, innerId: nil, animated: false, focus: true, inset: 0))
        }, results: { query in
            chatInteraction.modalSearch(query)
        }, calendarAction: { date in
            chatInteraction.jumpToDate(date)
        }, cancel: {
            chatInteraction.update({$0.updatedSearchMode((false, nil))})
        }, searchRequest: { query, fromId, state in
            let location: SearchMessagesLocation
            switch chatInteraction.chatLocation {
            case let .peer(peerId):
                location = .peer(peerId: peerId, fromId: fromId, tags: nil)
            }
            return searchMessages(account: context.account, location: location, query: query, state: state) |> map {($0.0.messages, $0.1)}
        })
        
        
        tableView.addScroll(listener: TableScrollListener { [weak self] position in
            if let state = self?.historyState {
                self?.updateScroller(state)
            }
        })
        
        tableView.backgroundColor = .clear
        tableView.layer?.backgroundColor = .clear

       // updateLocalizationAndTheme()
        
        tableView.set(stickClass: ChatDateStickItem.self, handler: { stick in
            
        })
    }
    
    func updateScroller(_ historyState:ChatHistoryState) {
        self.historyState = historyState
        let isHidden = (tableView.documentOffset.y < 150 && historyState.isDownOfHistory) || tableView.isEmpty
        if !isHidden {
            scroller.isHidden = false
        }
        
        scroller.change(opacity: isHidden ? 0 : 1, animated: true) { [weak scroller] completed in
            if completed {
                scroller?.isHidden = isHidden
            }
        }
        
        if let mentions = mentions {
            mentions.change(pos: NSMakePoint(frame.width - mentions.frame.width - 6, tableView.frame.maxY - mentions.frame.height - 6 - (scroller.controlIsHidden ? 0 : scroller.frame.height)), animated: true )
        }
    }
    
    
    func navigationHeaderDidNoticeAnimation(_ current: CGFloat, _ previous: CGFloat, _ animated: Bool) -> ()->Void {
        if let view = header.currentView {
            view.layer?.animatePosition(from: NSMakePoint(0, previous), to: NSMakePoint(0, current), removeOnCompletion: false)
            return { [weak view] in
                view?.layer?.removeAllAnimations()
            }
        }
        return {}
    }
    
    
    private var previousHeight:CGFloat = 50
    func inputChanged(height: CGFloat, animated: Bool) {
        if previousHeight != height {
            let header:CGFloat
            if let currentView = self.header.currentView {
                header = currentView.frame.height
            } else {
                header = 0
            }
            let size = NSMakeSize(frame.width, frame.height - height - header)
            let resizeAnimated = animated && tableView.contentOffset.y < height
            //(previousHeight < height || tableView.contentOffset.y < height)
            
            tableView.change(size: size, animated: resizeAnimated)
            
            if tableView.contentOffset.y > height {
                tableView.clipView.scroll(to: NSMakePoint(0, tableView.contentOffset.y - (previousHeight - height)))
            }
            
            inputView.change(pos: NSMakePoint(0, tableView.frame.maxY), animated: animated)
            if let view = inputContextHelper.accessoryView {
                view._change(pos: NSMakePoint(0, frame.height - inputView.frame.height - view.frame.height), animated: animated)
            }
            if let mentions = mentions {
                mentions.change(pos: NSMakePoint(frame.width - mentions.frame.width - 6, tableView.frame.maxY - mentions.frame.height - 6 - (scroller.controlIsHidden ? 0 : scroller.frame.height)), animated: animated )
            }
            scroller.change(pos: NSMakePoint(frame.width - scroller.frame.width - 6, size.height - scroller.frame.height - 6), animated: animated)
            
            
            previousHeight = height

        }
        
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    required init(frame frameRect: NSRect) {
        fatalError("init(frame:) has not been implemented")
    }
    
    override func setFrameSize(_ newSize: NSSize) {
        if let view = inputContextHelper.accessoryView {
            view.setFrameSize(NSMakeSize(newSize.width, view.frame.height))
        }
        
        if let currentView = header.currentView {
            currentView.setFrameSize(NSMakeSize(newSize.width, currentView.frame.height))
            tableView.setFrameSize(NSMakeSize(newSize.width, newSize.height - inputView.frame.height - currentView.frame.height))
        } else {
            tableView.setFrameSize(NSMakeSize(newSize.width, newSize.height - inputView.frame.height))
        }
        inputView.setFrameSize(NSMakeSize(newSize.width, inputView.frame.height))
        
        super.setFrameSize(newSize)

    }
    
    override func layout() {
        super.layout()
        header.currentView?.setFrameOrigin(NSZeroPoint)
        if let currentView = header.currentView {
            tableView.setFrameOrigin(0, currentView.frame.height)
            currentView.needsDisplay = true

        } else {
            tableView.setFrameOrigin(0, 0)
        }
        
        if let view = inputContextHelper.accessoryView {
            view.setFrameOrigin(0, frame.height - inputView.frame.height - view.frame.height)
        }
        inputView.setFrameOrigin(NSMakePoint(0, tableView.frame.maxY))
        if let indicator = progressView?.subviews.first {
            indicator.center()
        }
        
        progressView?.center()
        
        scroller.setFrameOrigin(frame.width - scroller.frame.width - 6, tableView.frame.height - 6 - scroller.frame.height)
        
        if let mentions = mentions {
            mentions.change(pos: NSMakePoint(frame.width - mentions.frame.width - 6, tableView.frame.maxY - mentions.frame.height - 6 - (scroller.controlIsHidden ? 0 : scroller.frame.height)), animated: false )
        }
    }
    

    override var responder: NSResponder? {
        return inputView.responder
    }
    
    func change(state:ChatControllerViewState, animated:Bool) {
        let state = chatInteraction.presentation.isNotAccessible ? .visible : state
        if state != self.state {
            self.state = state
            
            switch state {
            case .progress:
                if progressView == nil {
                    self.progressView = ProgressIndicator(frame: NSMakeRect(0,0,30,30))
                    
                    progressView!.animates = true
                    addSubview(progressView!)
                    progressView!.center()
                }
                progressView?.backgroundColor = theme.colors.background.withAlphaComponent(0.7)
                progressView?.layer?.cornerRadius = 15
            case .visible:
                if animated {
                    progressView?.layer?.animateAlpha(from: 1, to: 0, duration: 0.2, removeOnCompletion: false, completion: { [weak self] (completed) in
                        self?.progressView?.removeFromSuperview()
                        self?.progressView?.animates = false
                        self?.progressView = nil
                    })
                } else {
                    progressView?.removeFromSuperview()
                    progressView = nil
                }
            }
        }
        if chatInteraction.presentation.isNotAccessible {
            tableView.updateEmpties()
        }
    }
    
    func updateHeader(_ interfaceState:ChatPresentationInterfaceState, _ animated:Bool) {
        
        let state:ChatHeaderState
        if let initialAction = interfaceState.initialAction, case .ad = initialAction {
            state = .sponsored
        } else if interfaceState.isSearchMode.0 {
            state = .search(searchInteractions, interfaceState.isSearchMode.1)
        } else if interfaceState.reportStatus == .canReport {
            state = .report
        } else if let pinnedMessageId = interfaceState.pinnedMessageId, pinnedMessageId != interfaceState.interfaceState.dismissedPinnedMessageId {
            state = .pinned(pinnedMessageId)
        } else if let canAdd = interfaceState.canAddContact, canAdd {
           state = .none
        } else {
            state = .none
        }
        
        CATransaction.begin()
        header.updateState(state, animated: animated, for: self)
        
        
        tableView.change(size: NSMakeSize(frame.width, frame.height - state.height - inputView.frame.height), animated: animated)
        tableView.change(pos: NSMakePoint(0, state.height), animated: animated)
        
        scroller.change(pos: NSMakePoint(frame.width - scroller.frame.width - 6, frame.height - state.height - inputView.frame.height - 6 - scroller.frame.height), animated: animated)

        
        if let mentions = mentions {
            mentions.change(pos: NSMakePoint(frame.width - mentions.frame.width - 6, tableView.frame.maxY - mentions.frame.height - 6 - (scroller.controlIsHidden ? 0 : scroller.frame.height)), animated: animated )
        }
        
        if let view = inputContextHelper.accessoryView {
            view._change(pos: NSMakePoint(0, frame.height - view.frame.height - inputView.frame.height), animated: animated)
        }
        CATransaction.commit()
    }
    
    func updateMentionsCount(_ count: Int32, animated: Bool) {
        if count > 0 {
            if mentions == nil {
                mentions = ChatNavigationMention()
                mentions?.set(handler: { [weak self] _ in
                    self?.chatInteraction.mentionPressed()
                }, for: .Click)
                
                mentions?.set(handler: { [weak self] _ in
                    self?.chatInteraction.clearMentions()
                }, for: .LongMouseDown)
                
                if let mentions = mentions {
                    mentions.change(pos: NSMakePoint(frame.width - mentions.frame.width - 6, tableView.frame.maxY - mentions.frame.height - 6 - (scroller.controlIsHidden ? 0 : scroller.frame.height)), animated: animated )
                    addSubview(mentions)
                }             
            }
            mentions?.updateCount(count)
        } else {
            mentions?.removeFromSuperview()
            mentions = nil
        }
        needsLayout = true
    }
    
    func applySearchResponder() {
        (header.currentView as? ChatSearchHeader)?.applySearchResponder()
    }

    
    override func updateLocalizationAndTheme() {
        super.updateLocalizationAndTheme()
        progressView?.backgroundColor = theme.colors.background
        (progressView?.subviews.first as? ProgressIndicator)?.set(color: theme.colors.indicatorColor)
        scroller.updateLocalizationAndTheme()
        tableView.emptyItem = ChatEmptyPeerItem(tableView.frame.size, chatInteraction: chatInteraction)
    }

    
}




fileprivate func prepareEntries(from fromView:ChatHistoryView?, to toView:ChatHistoryView, timeDifference: TimeInterval, initialSize:NSSize, interaction:ChatInteraction, animated:Bool, scrollPosition:ChatHistoryViewScrollPosition?, reason:ChatHistoryViewUpdateType, animationInterface:TableAnimationInterface?, side: TableSavingSide?) -> Signal<TableUpdateTransition, NoError> {
    return Signal { subscriber in
    
        
        var scrollToItem:TableScrollState? = nil
        var animated = animated
        
        if let scrollPosition = scrollPosition {
            switch scrollPosition {
            case let .unread(unreadIndex):
                var index = toView.filteredEntries.count - 1
                for entry in toView.filteredEntries {
                    if case .UnreadEntry = entry.appearance.entry {
                        scrollToItem = .top(id: entry.stableId, innerId: nil, animated: false, focus: false, inset: -6)
                        break
                    }
                    index -= 1
                }
                
                if scrollToItem == nil {
                    scrollToItem = .none(animationInterface)
                }
                
                if scrollToItem == nil {
//                    var index = 0
//                    for entry in toView.filteredEntries.reversed() {
//                        if entry.appearance.entry.index < unreadIndex {
//                            scrollToItem = .top(id: entry.stableId, animated: false, focus: false, inset: 0)
//                            break
//                        }
//                        index += 1
//                    }
                }
            case let .positionRestoration(scrollIndex, relativeOffset):
                let scrollIndex = scrollIndex.withUpdatedTimestamp(scrollIndex.timestamp - Int32(timeDifference))
                var index = toView.filteredEntries.count - 1
                for entry in toView.filteredEntries {
                    if entry.appearance.entry.index >= scrollIndex {
                        scrollToItem = .top(id: entry.stableId, innerId: nil, animated: false, focus: false, inset: relativeOffset)
                        break
                    }
                    index -= 1
                }
                
                if scrollToItem == nil {
                    var index = 0
                    for entry in toView.filteredEntries.reversed() {
                        if entry.appearance.entry.index < scrollIndex {
                            scrollToItem = .top(id: entry.stableId, innerId: nil, animated: false, focus: false, inset: relativeOffset)
                            break
                        }
                        index += 1
                    }
                }
            case let .index(scrollIndex, position, directionHint, animated):
                let scrollIndex = scrollIndex.withSubstractedTimestamp(Int32(timeDifference))

                for entry in toView.filteredEntries {
                    if scrollIndex.isLessOrEqual(to: entry.appearance.entry.index) {
                        if case let .groupedPhotos(entries, _) = entry.appearance.entry {
                            for inner in entries {
                                if case let .MessageEntry(values) = inner {
                                    if !scrollIndex.isLess(than: MessageIndex(values.0.withUpdatedTimestamp(values.0.timestamp - Int32(timeDifference)))) && scrollIndex.isLessOrEqual(to: MessageIndex(values.0.withUpdatedTimestamp(values.0.timestamp - Int32(timeDifference)))) {
                                        scrollToItem = position.swap(to: entry.appearance.entry.stableId, innerId: inner.stableId)
                                    }
                                }
                            }
                        } else {
                            scrollToItem = position.swap(to: entry.appearance.entry.stableId)
                        }
                        break
                    }
                }
                
                if scrollToItem == nil {
                    var index = 0
                    for entry in toView.filteredEntries.reversed() {
                        if MessageHistoryAnchorIndex.message(entry.appearance.entry.index) < scrollIndex {
                            scrollToItem = position.swap(to: entry.appearance.entry.stableId)
                            break
                        }
                        index += 1
                    }
                }
            }
        }
        
        if scrollToItem == nil {
            scrollToItem = .saveVisible(side ?? .upper)
            
            switch reason {
            case let .Generic(type):
                switch type {
                case .Generic:
                    scrollToItem = .none(animationInterface)
                default:
                    break
                }
            default:
                break
            }
        } else {
            var bp:Int = 0
            bp += 1
        }
        
        
        func makeItem(_ entry: ChatWrapperEntry) -> TableRowItem {
            var item:TableRowItem;
            switch entry.appearance.entry {
            case .UnreadEntry:
                item = ChatUnreadRowItem(initialSize, interaction, interaction.context, entry.appearance.entry, entry.automaticDownload)
            case .MessageEntry:
                item = ChatRowItem.item(initialSize, from: entry.appearance.entry, interaction: interaction, downloadSettings: entry.automaticDownload)
            case .groupedPhotos:
                item = ChatGroupedItem(initialSize, interaction, interaction.context, entry.appearance.entry, entry.automaticDownload)
            case .DateEntry:
                item = ChatDateStickItem(initialSize, entry.appearance.entry, interaction: interaction)
            case .bottom:
                item = GeneralRowItem(initialSize, height: theme.bubbled ? 10 : 20, stableId: entry.stableId)
            }
            _ = item.makeSize(initialSize.width)
            return item;
        }
        
        let firstTransition = Queue.mainQueue().isCurrent()
        var cancelled = false
        
        if fromView == nil && firstTransition, let state = scrollToItem {
                        
            var initialIndex:Int = 0
            var height:CGFloat = 0
            var firstInsertion:[(Int, TableRowItem)] = []
            let entries = Array(toView.filteredEntries.reversed())
            
            switch state {
            case let .top(stableId, _, _, _, relativeOffset):
                var index:Int? = nil
                height = relativeOffset
                for k in 0 ..< entries.count {
                    if entries[k].stableId == stableId {
                        index = k
                        break
                    }
                }
                
                if let index = index {
                    var success:Bool = false
                    var j:Int = index
                    for i in stride(from: index, to: -1, by: -1) {
                        let item = makeItem(entries[i])
                        height += item.height
                        firstInsertion.append((index - j, item))
                        j -= 1
                        if initialSize.height < height {
                            success = true
                            break
                        }
                    }
                    
                    if !success {
                        for i in (index + 1) ..< entries.count {
                            let item = makeItem(entries[i])
                            height += item.height
                            firstInsertion.insert((0, item), at: 0)
                            if initialSize.height < height {
                                success = true
                                break
                            }
                        }
                    }
                    
                    var reversed:[(Int, TableRowItem)] = []
                    var k:Int = 0
                    
                    for f in firstInsertion.reversed() {
                        reversed.append((k, f.1))
                        k += 1
                    }
                
                    firstInsertion = reversed
                    

                    
                    if success {
                        initialIndex = (j + 1)
                    } else {
                        let alreadyInserted = firstInsertion.count
                        for i in alreadyInserted ..< entries.count {
                            let item = makeItem(entries[i])
                            height += item.height
                            firstInsertion.append((i, item))
                            if initialSize.height < height {
                                break
                            }
                        }
                    }
                    
                    
                }
            case let .center(stableId, _, _, _, _):
                
                var index:Int? = nil
                for k in 0 ..< entries.count {
                    if entries[k].stableId == stableId {
                        index = k
                        break
                    }
                }
                if let index = index {
                    let item = makeItem(entries[index])
                    height += item.height
                    firstInsertion.append((index, item))
                    
                    
                    var low: Int = index + 1
                    var high: Int = index - 1
                    var lowHeight: CGFloat = 0
                    var highHeight: CGFloat = 0
                    
                    var lowSuccess: Bool = low > entries.count - 1
                    var highSuccess: Bool = high < 0
                    
                    while !lowSuccess || !highSuccess {
                        
                        if  (initialSize.height / 2) >= lowHeight && !lowSuccess {
                            let item = makeItem(entries[low])
                            lowHeight += item.height
                            firstInsertion.append((low, item))
                        }
                        
                        if (initialSize.height / 2) >= highHeight && !highSuccess  {
                            let item = makeItem(entries[high])
                            highHeight += item.height
                            firstInsertion.append((high, item))
                        }
                        
                        if (((initialSize.height / 2) <= lowHeight ) || low == entries.count - 1) {
                            lowSuccess = true
                        } else if !lowSuccess {
                            low += 1
                        }
                        
                        
                        if (((initialSize.height / 2) <= highHeight) || high == 0) {
                            highSuccess = true
                        } else if !highSuccess {
                            high -= 1
                        }
                        
                        
                    }
                    
                    initialIndex = max(high, 0)
   
                    
                    firstInsertion.sort(by: { lhs, rhs -> Bool in
                        return lhs.0 < rhs.0
                    })
                    
                    var copy = firstInsertion
                    firstInsertion.removeAll()
                    for i in 0 ..< copy.count {
                        firstInsertion.append((i, copy[i].1))
                    }
                }
                
                
                break
            default:

                for i in 0 ..< entries.count {
                    let item = makeItem(entries[i])
                    firstInsertion.append((i, item))
                    height += item.height
                    
                    if initialSize.height < height {
                        break
                    }
                }
            }
            subscriber.putNext(TableUpdateTransition(deleted: [], inserted: firstInsertion, updated: [], state:state))
             
            
            messagesViewQueue.async {
                if !cancelled {
                    
                    var firstInsertedRange:NSRange = NSMakeRange(0, 0)
                    
                    if !firstInsertion.isEmpty {
                        firstInsertedRange = NSMakeRange(initialIndex, firstInsertion.count)
                    }
                    
                    var insertions:[(Int, TableRowItem)] = []
                    let updates:[(Int, TableRowItem)] = []
                    
                    for i in 0 ..< entries.count {
                        let item:TableRowItem
                        
                        if firstInsertedRange.indexIn(i) {
                            //item = firstInsertion[i - initialIndex].1
                            //updates.append((i, item))
                        } else {
                            item = makeItem(entries[i])
                            insertions.append((i, item))
                        }
                    }
                    
                    
                    subscriber.putNext(TableUpdateTransition(deleted: [], inserted: insertions, updated: updates, state: .saveVisible(.upper)))
                    subscriber.putCompletion()
                }
            }
            
        } else if let state = scrollToItem {
            let (removed,inserted,updated) = proccessEntries(fromView?.filteredEntries, right: toView.filteredEntries, { entry -> TableRowItem in
               return makeItem(entry)
            })
            let grouping: Bool
            if case .none = state {
                grouping = false
            } else {
                grouping = true
            }
            
            
            subscriber.putNext(TableUpdateTransition(deleted: removed, inserted: inserted, updated: updated, animated: animated, state: state, grouping: grouping))
            subscriber.putCompletion()
        }
        


        return ActionDisposable {
            cancelled = true
        }
    }
}



private func maxIncomingMessageIndexForEntries(_ entries: [ChatHistoryEntry], indexRange: (Int, Int)) -> MessageIndex? {
    if !entries.isEmpty {
        for i in (indexRange.0 ... indexRange.1).reversed() {
            if case let .MessageEntry(message, _, _, _, _, _, _, _, _) = entries[i], message.flags.contains(.Incoming) {
                return MessageIndex(message)
            }
        }
    }
    
    return nil
}

enum ChatHistoryViewTransitionReason {
    case Initial(fadeIn: Bool)
    case InteractiveChanges
    case HoleReload    
    case Reload
}


class ChatController: EditableViewController<ChatControllerView>, Notifable, TableViewDelegate {
    
    private var chatLocation:ChatLocation
    private let peerView = Promise<PostboxView?>()
    
    private let historyDisposable:MetaDisposable = MetaDisposable()
    private let peerDisposable:MetaDisposable = MetaDisposable()
    private let updatedChannelParticipants:MetaDisposable = MetaDisposable()
    private let sentMessageEventsDisposable = MetaDisposable()
    private let messageActionCallbackDisposable:MetaDisposable = MetaDisposable()
    private let shareContactDisposable:MetaDisposable = MetaDisposable()
    private let peerInputActivitiesDisposable:MetaDisposable = MetaDisposable()
    private let connectionStatusDisposable:MetaDisposable = MetaDisposable()
    private let messagesActionDisposable:MetaDisposable = MetaDisposable()
    private let unblockDisposable:MetaDisposable = MetaDisposable()
    private let updatePinnedDisposable:MetaDisposable = MetaDisposable()
    private let reportPeerDisposable:MetaDisposable = MetaDisposable()
    private let focusMessageDisposable:MetaDisposable = MetaDisposable()
    private let updateFontSizeDisposable:MetaDisposable = MetaDisposable()
    private let loadFwdMessagesDisposable:MetaDisposable = MetaDisposable()
    private let chatUnreadMentionCountDisposable:MetaDisposable = MetaDisposable()
    private let navigationActionDisposable:MetaDisposable = MetaDisposable()
    private let messageIndexDisposable: MetaDisposable = MetaDisposable()
    private let dateDisposable:MetaDisposable = MetaDisposable()
    private let interactiveReadingDisposable: MetaDisposable = MetaDisposable()
    private let showRightControlsDisposable: MetaDisposable = MetaDisposable()
    private let editMessageDisposable: MetaDisposable = MetaDisposable()
    private let deleteChatDisposable: MetaDisposable = MetaDisposable()
    private let loadSelectionMessagesDisposable: MetaDisposable = MetaDisposable()
    private let updateMediaDisposable = MetaDisposable()
    private let editCurrentMessagePhotoDisposable = MetaDisposable()
    private let failedMessageEventsDisposable = MetaDisposable()
    private let selectMessagePollOptionDisposables: DisposableDict<MessageId> = DisposableDict()
    private let onlineMemberCountDisposable = MetaDisposable()
    private let chatUndoDisposable = MetaDisposable()
    private let discussionDataLoadDisposable = MetaDisposable()
    
    private let searchState: ValuePromise<SearchMessagesResultState> = ValuePromise(SearchMessagesResultState("", []), ignoreRepeated: true)
    
    private let pollAnswersLoading: ValuePromise<[MessageId : Data]> = ValuePromise([:], ignoreRepeated: true)
    private let pollAnswersLoadingValue: Atomic<[MessageId : Data]> = Atomic(value: [:])

    private var pollAnswersLoadingSignal: Signal<[MessageId : Data], NoError> {
        return pollAnswersLoading.get()
    }
    private func update(_ f:([MessageId : Data])-> [MessageId : Data]) -> Void {
        pollAnswersLoading.set(pollAnswersLoadingValue.modify(f))
    }
    
    var chatInteraction:ChatInteraction
    
    var nextTransaction:TransactionHandler = TransactionHandler()
    
    private let _historyReady = Promise<Bool>()
    private var didSetHistoryReady = false

    
    private let location:Promise<ChatHistoryLocation> = Promise()
    private let _locationValue:Atomic<ChatHistoryLocation?> = Atomic(value: nil)
    private var locationValue:ChatHistoryLocation? {
        return _locationValue.with { $0 }
    }

    private func setLocation(_ location: ChatHistoryLocation) {
        _ = _locationValue.swap(location)
        self.location.set(.single(location))
    }
    
    private let maxVisibleIncomingMessageIndex = ValuePromise<MessageIndex>(ignoreRepeated: true)
    private let readHistoryDisposable = MetaDisposable()
    
    
    private let initialDataHandler:Promise<ChatHistoryCombinedInitialData> = Promise()

    let previousView = Atomic<ChatHistoryView?>(value: nil)
    
    
    private let botCallbackAlertMessage = Promise<(String?, Bool)>((nil, false))
    private var botCallbackAlertMessageDisposable: Disposable?
    
    private var selectTextController:ChatSelectText!
    
    private var contextQueryState: (ChatPresentationInputQuery?, Disposable)?
    private var urlPreviewQueryState: (String?, Disposable)?

    
    let layoutDisposable:MetaDisposable = MetaDisposable()
    
    
    private let messageProcessingManager = ChatMessageThrottledProcessingManager()
    private let unsupportedMessageProcessingManager = ChatMessageThrottledProcessingManager()
    private let messageMentionProcessingManager = ChatMessageThrottledProcessingManager(delay: 0.2)
    var historyState:ChatHistoryState = ChatHistoryState() {
        didSet {
            //if historyState != oldValue {
                genericView.updateScroller(historyState) // updateScroller()
            //}
        }
    }
    
    func clearReplyStack() {
        self.historyState = historyState.withClearReplies()
    }


    override func scrollup() -> Void {
        if let reply = historyState.reply() {
            chatInteraction.focusMessageId(nil, reply, .center(id: 0, innerId: nil, animated: true, focus: true, inset: 0))
            historyState = historyState.withRemovingReplies(max: reply)
        } else {
            if previousView.with({$0})?.originalView?.laterId != nil {
                setLocation(.Scroll(index: MessageHistoryAnchorIndex.upperBound, anchorIndex: MessageHistoryAnchorIndex.upperBound, sourceIndex: MessageHistoryAnchorIndex.lowerBound, scrollPosition: .down(true), count: requestCount, animated: true))
            } else {
                genericView.tableView.scroll(to: .down(true))
            }

        }
        
    }
    
    private var requestCount: Int {
        return Int(round(genericView.tableView.frame.height / 28)) + 30
    }
    
    func readyHistory() {
        if !didSetHistoryReady {
            didSetHistoryReady = true
            _historyReady.set(.single(true))
        }
    }
    
    override var sidebar:ViewController? {
        return context.sharedContext.bindings.entertainment()
    }
    
    func updateSidebar() {
        if FastSettings.sidebarShown && FastSettings.sidebarEnabled {
            (navigationController as? MajorNavigationController)?.genericView.setProportion(proportion: SplitProportion(min:380, max:800), state: .single)
            (navigationController as? MajorNavigationController)?.genericView.setProportion(proportion: SplitProportion(min:380+350, max:700), state: .dual)
        } else {
            (navigationController as? MajorNavigationController)?.genericView.removeProportion(state: .dual)
            (navigationController as? MajorNavigationController)?.genericView.setProportion(proportion: SplitProportion(min:380, max: .greatestFiniteMagnitude), state: .single)
        }
    }
    

    override func viewDidResized(_ size: NSSize) {
        super.viewDidResized(size)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        

        
        let previousView = self.previousView
        let context = self.context
        let atomicSize = self.atomicSize
        let chatInteraction = self.chatInteraction
        let nextTransaction = self.nextTransaction
        
        //context.account.viewTracker.forceUpdateCachedPeerData(peerId: chatLocation.peerId)

        
        genericView.tableView.emptyChecker = { [weak self] items in
            
            let filtred = items.filter { item in
                if let item = item as? ChatRowItem, let message = item.message {
                    if let action = message.media.first as? TelegramMediaAction {
                        switch action.action {
                        case .groupCreated:
                            return messageMainPeer(message)?.groupAccess.isCreator == false
                        case .groupMigratedToChannel:
                            return false
                        case .channelMigratedFromGroup:
                            return false
                        case .photoUpdated:
                            return messageMainPeer(message)?.groupAccess.isCreator == false
                        default:
                            return true
                        }
                    }
                    return true
                }
                return false
            }
            
            return filtred.isEmpty && self?.genericView.state != .progress
        }

        
        genericView.tableView.delegate = self
        updateSidebar()
        
        
        switch chatLocation {
        case let .peer(peerId):
            self.peerView.set(context.account.viewTracker.peerView(peerId, updateData: true) |> map {Optional($0)})
            let _ = checkPeerChatServiceActions(postbox: context.account.postbox, peerId: peerId).start()
        }
        

        context.globalPeerHandler.set(.single(chatLocation))
        

        let layout:Atomic<SplitViewState> = Atomic(value:context.sharedContext.layout)
        let fixedCombinedReadState = Atomic<MessageHistoryViewReadState?>(value: nil)
        layoutDisposable.set(context.sharedContext.layoutHandler.get().start(next: {[weak self] (state) in
            let previous = layout.swap(state)
            if previous != state, let navigation = self?.navigationController {
                self?.requestUpdateBackBar()
                if let modalAction = navigation.modalAction {
                    navigation.set(modalAction: modalAction, state != .single)
                }
            }
        }))
        
        selectTextController = ChatSelectText(genericView.tableView)
        
        let maxReadIndex:ValuePromise<MessageIndex?> = ValuePromise()
        var didSetReadIndex: Bool = false

        let historyViewUpdate1 = location.get() |> deliverOnMainQueue
            |> mapToSignal { [weak self] location -> Signal<(ChatHistoryViewUpdate, TableSavingSide?), NoError> in
                guard let `self` = self else { return .never() }
                
                
                let peerId = self.chatInteraction.peerId
                
                var additionalData: [AdditionalMessageHistoryViewData] = []
                additionalData.append(.cachedPeerData(peerId))
                additionalData.append(.cachedPeerDataMessages(peerId))
                additionalData.append(.peerNotificationSettings(peerId))
                additionalData.append(.preferencesEntry(PreferencesKeys.limitsConfiguration))
                additionalData.append(.preferencesEntry(ApplicationSpecificPreferencesKeys.autoplayMedia))
                additionalData.append(.preferencesEntry(ApplicationSpecificPreferencesKeys.automaticMediaDownloadSettings))
                if peerId.namespace == Namespaces.Peer.CloudChannel {
                    additionalData.append(.cacheEntry(cachedChannelAdminIdsEntryId(peerId: peerId)))
                    additionalData.append(.peer(peerId))
                }
                if peerId.namespace == Namespaces.Peer.CloudUser || peerId.namespace == Namespaces.Peer.SecretChat {
                    additionalData.append(.peerIsContact(peerId))
                }
                
                
                return chatHistoryViewForLocation(location, account: context.account, chatLocation: self.chatLocation, fixedCombinedReadStates: { nil }, tagMask: nil, additionalData: additionalData) |> beforeNext { viewUpdate in
                    switch viewUpdate {
                    case let .HistoryView(view, _, _, _):
                        if !didSetReadIndex {
                            maxReadIndex.set(view.maxReadIndex)
                            didSetReadIndex = true
                        }
                    default:
                        maxReadIndex.set(nil)
                    }
                    } |> map { view in
                        return (view, location.side)
                }
        }
        let historyViewUpdate = historyViewUpdate1
//        |> take(until: { view in
//            switch view.0 {
//                case let .HistoryView(historyView):
//                    if case .Generic(.FillHole) = historyView.type {
//                        return SignalTakeAction(passthrough: true, complete: true)
//                    }
//                default:
//                    break
//            }
//            return SignalTakeAction(passthrough: true, complete: false)
//        }) |> then(.never())
        
        
        let previousAppearance:Atomic<Appearance> = Atomic(value: appAppearance)
        let firstInitialUpdate:Atomic<Bool> = Atomic(value: true)
        
        //let autoremovingUnreadMark:Promise<Bool?> = Promise(nil)

        let applyHole:() -> Void = { [weak self] in
            guard let `self` = self else { return }
            
            let visibleRows = self.genericView.tableView.visibleRows()
            var messageIndex: MessageIndex?
            for i in stride(from: visibleRows.max - 1, to: -1, by: -1) {
                if let item = self.genericView.tableView.item(at: i) as? ChatRowItem {
                    messageIndex = item.entry.index
                    break
                }
            }
            
            if let messageIndex = messageIndex {
                self.setLocation(.Navigation(index: MessageHistoryAnchorIndex.message(messageIndex), anchorIndex: MessageHistoryAnchorIndex.message(messageIndex), count: self.requestCount, side: .upper))
            } else if let location = self.locationValue {
                self.setLocation(location)
            }
            
            
//            let historyView = (strongSelf.opaqueTransactionState as? ChatHistoryTransactionOpaqueState)?.historyView
//            let displayRange = strongSelf.displayedItemRange
//            if let filteredEntries = historyView?.filteredEntries, let visibleRange = displayRange.visibleRange {
//                let lastEntry = filteredEntries[filteredEntries.count - 1 - visibleRange.lastIndex]
//
//                strongSelf.chatHistoryLocationValue = ChatHistoryLocationInput(content: .Navigation(index: .message(lastEntry.index), anchorIndex: .message(lastEntry.index), count: historyMessageCount), id: 0)
//            } else {
//                if let messageId = messageId {
//                    strongSelf.chatHistoryLocationValue = ChatHistoryLocationInput(content: .InitialSearch(location: .id(messageId), count: 60), id: 0)
//                } else {
//                    strongSelf.chatHistoryLocationValue = ChatHistoryLocationInput(content: .Initial(count: 60), id: 0)
//                }
//            }
        }
        
        let clearHistoryUndoSignal = context.chatUndoManager.status(for: chatInteraction.peerId, type: .clearHistory)
        
        let _searchState: Atomic<SearchMessagesResultState> = Atomic(value: SearchMessagesResultState("", []))
        
        let historyViewTransition = combineLatest(queue: messagesViewQueue, historyViewUpdate, appearanceSignal, combineLatest(maxReadIndex.get() |> deliverOnMessagesViewQueue, pollAnswersLoadingSignal), clearHistoryUndoSignal, searchState.get()) |> mapToQueue { update, appearance, readIndexAndPollAnswers, clearHistoryStatus, searchState -> Signal<(TableUpdateTransition, MessageHistoryView?, ChatHistoryCombinedInitialData, Bool), NoError> in
            
            //NSLog("get history")
            
            let maxReadIndex = readIndexAndPollAnswers.0
            let pollAnswersLoading = readIndexAndPollAnswers.1
            
            let searchStateUpdated = _searchState.swap(searchState) != searchState
            
            let isLoading: Bool
            let view: MessageHistoryView?
            let initialData: ChatHistoryCombinedInitialData
            let updateType: ChatHistoryViewUpdateType
            let scrollPosition: ChatHistoryViewScrollPosition?
            switch update.0 {
            case let .Loading(data, ut):
                view = nil
                initialData = data
                isLoading = true
                updateType = ut
                scrollPosition = nil
            case let .HistoryView(values):
                initialData = values.initialData
                view = values.view
                isLoading = values.view.isLoading
                updateType = values.type
                scrollPosition = searchStateUpdated ? nil : values.scrollPosition
            }
            
            switch updateType {
            case let .Generic(type: type):
                switch type {
                case .FillHole:
                 //   location.set(self.location.get() |> take(1))
                    NSLog("fill hole")
                    Queue.mainQueue().async {
                         applyHole()
                    }
                    return .complete()
                default:
                    break
                }
            default:
                break
            }
            
            
            let pAppearance = previousAppearance.swap(appearance)
            var prepareOnMainQueue = pAppearance.presentation != appearance.presentation
            switch updateType {
            case .Initial:
                prepareOnMainQueue = firstInitialUpdate.swap(false) || prepareOnMainQueue
            default:
                break
            }
            let animationInterface: TableAnimationInterface = TableAnimationInterface(nextTransaction.isExutable && view?.laterId == nil)
            let timeDifference = context.timeDifference
            
            
            var adminIds: Set<PeerId> = Set()
            if let view = view {
                for additionalEntry in view.additionalData {
                    if case let .cacheEntry(id, data) = additionalEntry {
                        if id == cachedChannelAdminIdsEntryId(peerId: chatInteraction.peerId), let data = data as? CachedChannelAdminIds {
                            adminIds = data.ids
                        }
                        break
                    }
                }
            }
           
            
            let proccesedView:ChatHistoryView
            if let view = view {
                if let peer = chatInteraction.peer, peer.isRestrictedChannel {
                    proccesedView = ChatHistoryView(originalView: view, filteredEntries: [])
                } else if let clearHistoryStatus = clearHistoryStatus, clearHistoryStatus != .cancelled {
                    proccesedView = ChatHistoryView(originalView: view, filteredEntries: [])
                } else {
                    let entries = messageEntries(view.entries, maxReadIndex: maxReadIndex, dayGrouping: true, renderType: appearance.presentation.bubbled ? .bubble : .list, includeBottom: true, timeDifference: timeDifference, adminIds: adminIds, pollAnswersLoading: pollAnswersLoading, groupingPhotos: true, autoplayMedia: initialData.autoplayMedia, searchState: searchState).map({ChatWrapperEntry(appearance: AppearanceWrapperEntry(entry: $0, appearance: appearance), automaticDownload: initialData.autodownloadSettings)})
                    proccesedView = ChatHistoryView(originalView: view, filteredEntries: entries)
                }
            } else {
                proccesedView = ChatHistoryView(originalView: nil, filteredEntries: [])
            }
            
            
            return prepareEntries(from: previousView.swap(proccesedView), to: proccesedView, timeDifference: timeDifference, initialSize: atomicSize.modify({$0}), interaction: chatInteraction, animated: false, scrollPosition:scrollPosition, reason: updateType, animationInterface: animationInterface, side: update.1) |> map { transition in
                return (transition, view, initialData, isLoading)
            } |> runOn(prepareOnMainQueue ? Queue.mainQueue(): messagesViewQueue)
            
        } |> deliverOnMainQueue
        
        
        let appliedTransition = historyViewTransition |> map { [weak self] transition, view, initialData, isLoading  in
            self?.applyTransition(transition, view: view, initialData: initialData, isLoading: isLoading)
        }
        
        
        self.historyDisposable.set(appliedTransition.start())
        
        let previousMaxIncomingMessageIdByNamespace = Atomic<[MessageId.Namespace: MessageIndex]>(value: [:])
        let readHistory = combineLatest(self.maxVisibleIncomingMessageIndex.get(), self.isKeyWindow.get())
            |> map { [weak self] messageIndex, canRead in
                guard let `self` = self else {return}
                if canRead {
                    var apply = false
                    let _ = previousMaxIncomingMessageIdByNamespace.modify { dict in
                        let previousIndex = dict[messageIndex.id.namespace]
                        if previousIndex == nil || previousIndex! < messageIndex {
                            apply = true
                            var dict = dict
                            dict[messageIndex.id.namespace] = messageIndex
                            return dict
                        }
                        return dict
                    }
                    if apply {
                        switch self.chatLocation {
                        case let .peer(peerId):
                            clearNotifies(peerId, maxId: messageIndex.id)
                            _ = applyMaxReadIndexInteractively(postbox: context.account.postbox, stateManager: context.account.stateManager, index: messageIndex).start()
                        }
                    }
                }
        }
        
        self.readHistoryDisposable.set(readHistory.start())
        
        

        
        chatInteraction.setupReplyMessage = { [weak self] messageId in
            guard let `self` = self else { return }
            
            
            self.chatInteraction.focusInputField()
            let signal:Signal<Message?, NoError> = messageId == nil ? .single(nil) : self.chatInteraction.context.account.postbox.messageAtId(messageId!)
            _ = (signal |> deliverOnMainQueue).start(next: { [weak self] message in
                self?.chatInteraction.update({ current in
                    var current = current.updatedInterfaceState({$0.withUpdatedReplyMessageId(messageId).withUpdatedReplyMessage(message)})
                    if messageId == current.keyboardButtonsMessage?.replyAttribute?.messageId {
                        current = current.updatedInterfaceState({$0.withUpdatedDismissedForceReplyId(messageId)})
                    }
                    return current
                })
            })
            
            
        }
        
        chatInteraction.startRecording = { [weak self] hold in
            guard let chatInteraction = self?.chatInteraction else {return}
            if chatInteraction.presentation.recordingState != nil || chatInteraction.presentation.state != .normal {
                NSSound.beep()
                return
            }
            if let peer = chatInteraction.presentation.peer {
                if let permissionText = permissionText(from: peer, for: .banSendMedia) {
                    alert(for: mainWindow, info: permissionText)
                    return
                }
                if chatInteraction.presentation.effectiveInput.inputText.isEmpty {
                    let state: ChatRecordingState
                    
                    switch FastSettings.recordingState {
                    case .voice:
                        state = ChatRecordingAudioState(account: chatInteraction.context.account, liveUpload: chatInteraction.peerId.namespace != Namespaces.Peer.SecretChat, autohold: hold)
                        state.start()
                    case .video:
                        state = ChatRecordingVideoState(account: chatInteraction.context.account, liveUpload: chatInteraction.peerId.namespace != Namespaces.Peer.SecretChat, autohold: hold)
                        showModal(with: VideoRecorderModalController(chatInteraction: chatInteraction, pipeline: (state as! ChatRecordingVideoState).pipeline), for: mainWindow)
                    }
                    
                    chatInteraction.update({$0.withRecordingState(state)})
                }
            }
        }
        
        let scrollAfterSend:()->Void = { [weak self] in
            guard let `self` = self else { return }
            self.chatInteraction.scrollToLatest(true)
            self.context.sharedContext.bindings.entertainment().closePopover()
            self.context.cancelGlobalSearch.set(true)
        }
        
        
        let afterSentTransition = { [weak self] in
           self?.chatInteraction.update({ presentation in
            return presentation.updatedInputQueryResult({_ in return nil}).updatedInterfaceState { current in
                
                var value: ChatInterfaceState = current.withUpdatedReplyMessageId(nil).withUpdatedInputState(ChatTextInputState()).withUpdatedForwardMessageIds([]).withUpdatedComposeDisableUrlPreview(nil)
            
            
                if let message = presentation.keyboardButtonsMessage, let replyMarkup = message.replyMarkup {
                    if replyMarkup.flags.contains(.setupReply) {
                        value = value.withUpdatedDismissedForceReplyId(message.id)
                    }
                }
                return value
            }.updatedUrlPreview(nil)
            
           })
            self?.chatInteraction.saveState(scrollState: self?.immediateScrollState())
        }
        
        chatInteraction.jumpToDate = { [weak self] date in
            if let window = self?.window, let peerId = self?.chatInteraction.peerId {
                let signal = searchMessageIdByTimestamp(account: context.account, peerId: peerId, timestamp: Int32(date.timeIntervalSince1970) - Int32(NSTimeZone.local.secondsFromGMT()))
                
                self?.dateDisposable.set(showModalProgress(signal: signal, for: window).start(next: { messageId in
                    if let messageId = messageId {
                        self?.chatInteraction.focusMessageId(nil, messageId, .top(id: 0, innerId: nil, animated: true, focus: false, inset: 30))
                    }
                }, error: { error in
                    var bp:Int = 0
                    bp += 1
                }))
            }
        }
       
        let editMessage:(ChatEditState)->Void = { [weak self] state in
            guard let `self` = self else {return}
            let presentation = self.chatInteraction.presentation
            let inputState = state.inputState.subInputState(from: NSMakeRange(0, state.inputState.inputText.length))
            self.urlPreviewQueryState?.1.dispose()
            self.chatInteraction.update({$0.updatedUrlPreview(nil).updatedInterfaceState({$0.updatedEditState({$0?.withUpdatedLoadingState(state.editMedia == .keep ? .loading : .progress(0.2))})})})
            self.editMessageDisposable.set((requestEditMessage(account: context.account, messageId: state.message.id, text: inputState.inputText, media: state.editMedia, entities: TextEntitiesMessageAttribute(entities: inputState.messageTextEntities), disableUrlPreview: presentation.interfaceState.composeDisableUrlPreview != nil)
            |> deliverOnMainQueue).start(next: { [weak self] progress in
                    guard let `self` = self else {return}
                    switch progress {
                    case let .progress(progress):
                        if state.editMedia != .keep {
                            self.chatInteraction.update({$0.updatedInterfaceState({$0.updatedEditState({$0?.withUpdatedLoadingState(.progress(max(progress, 0.2)))})})})
                        }
                    default:
                        break
                    }
                    
            }, completed: { [weak self] in
                guard let `self` = self else {return}
                self.chatInteraction.beginEditingMessage(nil)
               // self?.chatInteraction.update({$0.updatedInterfaceState({$0.updatedEditState({$0?.withUpdatedLoadingState(.none)})})})
                self.chatInteraction.update({
                    $0.updatedInterfaceState({
                        $0.withUpdatedComposeDisableUrlPreview(nil).updatedEditState({
                            $0?.withUpdatedLoadingState(.none)
                        })
                    })
                })
            }))
        }
        
        chatInteraction.sendMessage = { [weak self] in
            if let strongSelf = self {
                let presentation = strongSelf.chatInteraction.presentation
                let peerId = strongSelf.chatInteraction.peerId
                
                if presentation.abilityToSend {
                    
                    var invokeSignal:Signal<Never, NoError> = .complete()
                    
                    var setNextToTransaction = false
                    if let state = presentation.interfaceState.editState {
                        editMessage(state)
                        return
                    } else  if !presentation.effectiveInput.inputText.trimmed.isEmpty {
                        setNextToTransaction = true
                        
                        invokeSignal = Sender.enqueue(input: presentation.effectiveInput, context: context, peerId: strongSelf.chatInteraction.peerId, replyId: presentation.interfaceState.replyMessageId, disablePreview: presentation.interfaceState.composeDisableUrlPreview != nil) |> deliverOnMainQueue |> ignoreValues
                        
                       // let _ = (.start(completed: scrollAfterSend)
                    }
                    
                    let fwdIds: [MessageId] = presentation.interfaceState.forwardMessageIds
                    if !fwdIds.isEmpty {
                        setNextToTransaction = true
                        
                        
                        let fwd = combineLatest(queue: .mainQueue(), context.account.postbox.messagesAtIds(fwdIds), context.account.postbox.loadedPeerWithId(peerId)) |> mapToSignal { messages, peer -> Signal<[MessageId?], NoError> in
                            let errors:[String] = messages.compactMap { message in
                                
                                for attr in message.attributes {
                                    if let _ = attr as? InlineBotMessageAttribute, peer.hasBannedRights(.banSendInline) {
                                        return permissionText(from: peer, for: .banSendInline)
                                    }
                                }
                                
                                if let media = message.media.first {
                                    switch media {
                                    case _ as TelegramMediaPoll:
                                        return permissionText(from: peer, for: .banSendPolls)
                                    case _ as TelegramMediaImage:
                                        return permissionText(from: peer, for: .banSendMedia)
                                    case let file as TelegramMediaFile:
                                        if file.isAnimated && file.isVideo {
                                            return permissionText(from: peer, for: .banSendGifs)
                                        } else if file.isSticker {
                                            return permissionText(from: peer, for: .banSendStickers)
                                        } else {
                                            return permissionText(from: peer, for: .banSendMedia)
                                        }
                                    case _ as TelegramMediaGame:
                                        return permissionText(from: peer, for: .banSendGames)
                                    default:
                                        return nil
                                    }
                                }
                                
                                return nil
                            }
                            
                            if !errors.isEmpty {
                                alert(for: mainWindow, info: errors.joined(separator: "\n\n"))
                                return .complete()
                            }
                            
                            return Sender.forwardMessages(messageIds: messages.map {$0.id}, context: context, peerId: peerId)
                        }
                        
                        invokeSignal = invokeSignal |> then( fwd |> ignoreValues)
                        
                    }
                    
                    _ = (invokeSignal |> deliverOnMainQueue).start(completed: scrollAfterSend)
                    
                    if setNextToTransaction {
                        strongSelf.nextTransaction.set(handler: afterSentTransition)
                    }
                } else {
                    if let editState = presentation.interfaceState.editState, editState.inputState.inputText.isEmpty {
                        if editState.message.media.isEmpty || editState.message.media.first is TelegramMediaWebpage {
                            strongSelf.chatInteraction.deleteMessages([editState.message.id])
                            return
                        }
                    }
                    NSSound.beep()
                }
            }
        }
        
        chatInteraction.updateEditingMessageMedia = { [weak self] exts, asMedia in
            guard let `self` = self else {return}
            
            filePanel(with: exts, allowMultiple: false, for: mainWindow, completion: { [weak self] files in
                guard let `self` = self else {return}
                if let file = files?.first {
                    self.updateMediaDisposable.set((Sender.generateMedia(for: MediaSenderContainer(path: file, isFile: !asMedia), account: context.account) |> deliverOnMainQueue).start(next: { [weak self] media, _ in
                        self?.chatInteraction.update({$0.updatedInterfaceState({$0.updatedEditState({$0?.withUpdatedMedia(media)})})})
                    }))
                }
            })
        }
        
        chatInteraction.forceSendMessage = { [weak self] input in
            if let strongSelf = self, let peer = self?.chatInteraction.presentation.peer, peer.canSendMessage {
                let _ = (Sender.enqueue(input: input, context: context, peerId: strongSelf.chatInteraction.peerId, replyId: strongSelf.chatInteraction.presentation.interfaceState.replyMessageId) |> deliverOnMainQueue).start(completed: scrollAfterSend)
            }
        }
        
        chatInteraction.sendPlainText = { [weak self] text in
            if let strongSelf = self, let peer = self?.chatInteraction.presentation.peer, peer.canSendMessage {
                let _ = (Sender.enqueue(input: ChatTextInputState(inputText: text), context: context, peerId: strongSelf.chatInteraction.peerId, replyId: strongSelf.chatInteraction.presentation.interfaceState.replyMessageId) |> deliverOnMainQueue).start(completed: scrollAfterSend)
            }
        }
        
        chatInteraction.sendLocation = { [weak self] coordinate, venue in
            guard let `self` = self else {return}
            _ = Sender.enqueue(media: TelegramMediaMap(latitude: coordinate.latitude, longitude: coordinate.longitude, geoPlace: nil, venue: venue, liveBroadcastingTimeout: nil), context: context, peerId: self.chatInteraction.peerId, chatInteraction: self.chatInteraction).start(completed: scrollAfterSend)
        }
        
        chatInteraction.scrollToLatest = { [weak self] removeStack in
            if let strongSelf = self {
                if removeStack {
                    strongSelf.historyState = strongSelf.historyState.withClearReplies()
                }
                strongSelf.scrollup()
            }
        }
        
        chatInteraction.forwardMessages = { forwardMessages in
            showModal(with: ShareModalController(ForwardMessagesObject(context, messageIds: forwardMessages)), for: mainWindow)
        }
        
        chatInteraction.deleteMessages = { [weak self] messageIds in
            if let strongSelf = self, let peer = strongSelf.chatInteraction.peer {
                
                let channelAdmin:Promise<[ChannelParticipant]?> = Promise()
                    
                if peer.isSupergroup {
                    let disposable: MetaDisposable = MetaDisposable()
                    let result = context.peerChannelMemberCategoriesContextsManager.admins(postbox: context.account.postbox, network: context.account.network, accountPeerId: context.peerId, peerId: peer.id, updated: { state in
                        switch state.loadingState {
                        case .ready:
                            channelAdmin.set(.single(state.list.map({$0.participant})))
                            disposable.dispose()
                        default:
                            break
                        }
                    })
                    disposable.set(result.0)
                } else {
                    channelAdmin.set(.single(nil))
                }
                

                
                self?.messagesActionDisposable.set(combineLatest(context.account.postbox.messagesAtIds(messageIds) |> deliverOnMainQueue, channelAdmin.get() |> deliverOnMainQueue).start( next:{ [weak strongSelf] messages, admins in
                    if let strongSelf = strongSelf, let peer = strongSelf.chatInteraction.peer {
                        var canDelete:Bool = true
                        var canDeleteForEveryone = true
                        var unsendMyMessages: Bool = peer.id != context.peerId
                        var otherCounter:Int32 = 0
                        for message in messages {
                            if !canDeleteMessage(message, account: context.account) {
                                canDelete = false
                            }
                            if !canDeleteForEveryoneMessage(message, context: context) {
                                canDeleteForEveryone = false
                                unsendMyMessages = false
                            } else {
                                if message.author?.id != context.peerId && !(context.limitConfiguration.canRemoveIncomingMessagesInPrivateChats && message.peers[message.id.peerId] is TelegramUser)  {
                                    otherCounter += 1
                                }
                            }
                        }
                        
                        if otherCounter > 0 || peer.id == context.peerId {
                            canDeleteForEveryone = false
                        }
                        if messages.isEmpty {
                            strongSelf.chatInteraction.update({$0.withoutSelectionState()})
                            return
                        }
                        
                        if canDelete {
                            let isAdmin = admins?.filter({$0.peerId == messages[0].author?.id}).first != nil
                            if mustManageDeleteMessages(messages, for: peer, account: context.account), let memberId = messages[0].author?.id, !isAdmin {
                                showModal(with: DeleteSupergroupMessagesModalController(context: context, messageIds: messages.map {$0.id}, peerId: peer.id, memberId: memberId, onComplete: { [weak strongSelf] in
                                    strongSelf?.chatInteraction.update({$0.withoutSelectionState()})
                                }), for: mainWindow)
                            } else {
                                let thrid:String? = canDeleteForEveryone ? peer.isUser ? L10n.chatMessageDeleteForMeAndPerson(peer.compactDisplayTitle) : L10n.chatConfirmDeleteMessagesForEveryone : unsendMyMessages ? L10n.chatMessageUnsendMessages : nil
                                
                               
                              
                                if let window = self?.window {
                                    modernConfirm(for: window, account: context.account, peerId: nil, header: thrid == nil ? L10n.chatConfirmActionUndonable : L10n.chatConfirmDeleteMessages, information: thrid == nil ? L10n.chatConfirmDeleteMessages : nil, okTitle: tr(L10n.confirmDelete), thridTitle: thrid, successHandler: { [weak strongSelf] result in
                                        
                                        guard let strongSelf = strongSelf else {return}
                                        
                                        let type:InteractiveMessagesDeletionType
                                        switch result {
                                        case .basic:
                                            type = .forLocalPeer
                                        case .thrid:
                                            type = .forEveryone
                                        }
                                        if let editingState = strongSelf.chatInteraction.presentation.interfaceState.editState {
                                            if messageIds.contains(editingState.message.id) {
                                                strongSelf.chatInteraction.update({$0.withoutEditMessage()})
                                            }
                                        }
                                        _ = deleteMessagesInteractively(postbox: context.account.postbox, messageIds: messageIds, type: type).start()
                                        strongSelf.chatInteraction.update({$0.withoutSelectionState()})
                                    })
                                }
                            }
                        }
                    }
                }))
            }
        }
        
        chatInteraction.openInfo = { [weak self] (peerId, toChat, postId, action) in
            if let strongSelf = self {
                if toChat {
                    if peerId == strongSelf.chatInteraction.peerId {
                        if let postId = postId {
                            strongSelf.chatInteraction.focusMessageId(nil, postId, TableScrollState.center(id: 0, innerId: nil, animated: true, focus: true, inset: 0))
                        }
                    } else {
                       strongSelf.navigationController?.push(ChatAdditionController(context: context, chatLocation: .peer(peerId), messageId: postId, initialAction: action))
                    }
                } else {
                   strongSelf.navigationController?.push(PeerInfoController(context: context, peerId: peerId))
                }
            }
        }
        
        chatInteraction.showNextPost = { [weak self] in
            guard let `self` = self else {return}
            if let bottomVisibleRow = self.genericView.tableView.bottomVisibleRow {
                if bottomVisibleRow > 0 {
                    var item = self.genericView.tableView.item(at: bottomVisibleRow - 1)
                    if item.view?.visibleRect.height != item.view?.frame.height {
                        item = self.genericView.tableView.item(at: bottomVisibleRow)
                    }
                    self.genericView.tableView.scroll(to: .center(id: item.stableId, innerId: nil, animated: true, focus: true, inset: 0), inset: NSEdgeInsets(), true)
                }
                
            }
        }
        
        chatInteraction.openFeedInfo = { [weak self] groupId in
            guard let `self` = self else {return}
            self.navigationController?.push(ChatListController(context, groupId: groupId))
        }
        
        chatInteraction.openProxySettings = { [weak self] in
            let controller = proxyListController(accountManager: context.sharedContext.accountManager, network: context.account.network, pushController: { [weak self] controller in
                 self?.navigationController?.push(controller)
            })
            self?.navigationController?.push(controller)
        }
        
        chatInteraction.inlineAudioPlayer = { [weak self] controller in
            if let navigation = self?.navigationController {
                if let header = navigation.header, let strongSelf = self {
                    header.show(true)
                    if let view = header.view as? InlineAudioPlayerView {
                        view.update(with: controller, context: context, tableView: strongSelf.genericView.tableView)
                    }
                }
            }
        }
        chatInteraction.searchPeerMessages = { [weak self] peer in
            guard let `self` = self else { return }
            self.chatInteraction.update({$0.updatedSearchMode((false, nil))})
            self.chatInteraction.update({$0.updatedSearchMode((true, peer))})
        }
        chatInteraction.movePeerToInput = { [weak self] (peer) in
            if let strongSelf = self {
                let textInputState = strongSelf.chatInteraction.presentation.effectiveInput
                if let (range, _, _) = textInputStateContextQueryRangeAndType(textInputState, includeContext: false) {
                    let inputText = textInputState.inputText
                    
                    let name:String = peer.addressName ?? peer.compactDisplayTitle
                    
                    let distance = inputText.distance(from: range.lowerBound, to: range.upperBound)
                    let replacementText = name + " "
                    
                    let atLength = peer.addressName != nil ? 0 : 1
                    
                    let range = strongSelf.chatInteraction.appendText(replacementText, selectedRange: textInputState.selectionRange.lowerBound - distance - atLength ..< textInputState.selectionRange.upperBound)
                    
                    if peer.addressName == nil {
                        let state = strongSelf.chatInteraction.presentation.effectiveInput
                        var attributes = state.attributes
                        attributes.append(.uid(range.lowerBound ..< range.upperBound - 1, peer.id.id))
                        let updatedState = ChatTextInputState(inputText: state.inputText, selectionRange: state.selectionRange, attributes: attributes)
                        strongSelf.chatInteraction.update({$0.withUpdatedEffectiveInputState(updatedState)})
                    }
                }
            }
        }
        
        
        chatInteraction.sendInlineResult = { [weak self] (results,result) in
            if let strongSelf = self {
                if let message = outgoingMessageWithChatContextResult(to: strongSelf.chatInteraction.peerId, results: results, result: result) {
                    _ = (Sender.enqueue(message: message.withUpdatedReplyToMessageId(strongSelf.chatInteraction.presentation.interfaceState.replyMessageId), context: context, peerId: strongSelf.chatInteraction.peerId) |> deliverOnMainQueue).start(completed: scrollAfterSend)
                    strongSelf.nextTransaction.set(handler: afterSentTransition)
                }
            }
            
        }
        
        chatInteraction.beginEditingMessage = { [weak self] (message) in
            if let message = message {
                self?.chatInteraction.update({$0.withEditMessage(message)})
            } else {
                self?.chatInteraction.update({$0.withoutEditMessage()})
            }
            self?.chatInteraction.focusInputField()
        }
        
        chatInteraction.mentionPressed = { [weak self] in
            if let strongSelf = self {
                let signal = earliestUnseenPersonalMentionMessage(account: context.account, peerId: strongSelf.chatInteraction.peerId)
                strongSelf.navigationActionDisposable.set((signal |> deliverOnMainQueue).start(next: { [weak strongSelf] result in
                    if let strongSelf = strongSelf {
                        switch result {
                        case .loading:
                            break
                        case .result(let messageId):
                            if let messageId = messageId {
                                strongSelf.chatInteraction.focusMessageId(nil, messageId, .center(id: 0, innerId: nil, animated: true, focus: true, inset: 0))
                            }
                        }
                    }
                }))
            }
        }
        
        chatInteraction.clearMentions = { [weak self] in
            guard let `self` = self else {return}
            _ = clearPeerUnseenPersonalMessagesInteractively(account: context.account, peerId: self.chatInteraction.peerId).start()
        }
        
        chatInteraction.editEditingMessagePhoto = { [weak self] media in
            guard let `self` = self else {return}
            if let resource = media.representationForDisplayAtSize(NSMakeSize(1280, 1280))?.resource {
                _ = (context.account.postbox.mediaBox.resourceData(resource) |> deliverOnMainQueue).start(next: { [weak self] resource in
                    guard let `self` = self else {return}
                    let url = URL(fileURLWithPath: link(path:resource.path, ext:kMediaImageExt)!)
                    let controller = EditImageModalController(url, defaultData: self.chatInteraction.presentation.interfaceState.editState?.editedData)
                    self.editCurrentMessagePhotoDisposable.set((controller.result |> deliverOnMainQueue).start(next: { [weak self] (new, data) in
                        guard let `self` = self else {return}
                        self.chatInteraction.update({$0.updatedInterfaceState({$0.updatedEditState({$0?.withUpdatedEditedData(data)})})})
                        if new != url {
                            self.updateMediaDisposable.set((Sender.generateMedia(for: MediaSenderContainer(path: new.path, isFile: false), account: context.account) |> deliverOnMainQueue).start(next: { [weak self] media, _ in
                                self?.chatInteraction.update({$0.updatedInterfaceState({$0.updatedEditState({$0?.withUpdatedMedia(media)})})})
                            }))
                        } else {
                            self.chatInteraction.update({$0.updatedInterfaceState({$0.updatedEditState({$0?.withUpdatedMedia(media)})})})
                        }
                        
                    }))
                    showModal(with: controller, for: mainWindow)
                })
            }
        }
        
        chatInteraction.requestMessageActionCallback = { [weak self] messageId, isGame, data in
            if let strongSelf = self {
                strongSelf.botCallbackAlertMessage.set(.single((L10n.chatInlineRequestLoading, false)))
                strongSelf.messageActionCallbackDisposable.set((requestMessageActionCallback(account: context.account, messageId: messageId, isGame:isGame, data: data) |> deliverOnMainQueue).start(next: { [weak strongSelf] (result) in
                    
                    if let strongSelf = strongSelf {
                        switch result {
                        case .none:
                            strongSelf.botCallbackAlertMessage.set(.single(("", false)))
                        case let .toast(text):
                            strongSelf.botCallbackAlertMessage.set(.single((text, false)))
                        case let .alert(text):
                            strongSelf.botCallbackAlertMessage.set(.single((text, true)))
                        case let .url(url):
                            if isGame {
                                strongSelf.navigationController?.push(WebGameViewController(context, strongSelf.chatInteraction.peerId, messageId, url))
                            } else {
                                execute(inapp: .external(link: url, !(strongSelf.chatInteraction.peer?.isVerified ?? false)))
                            }
                        }
                    }
                }))
            }
        }
        
        chatInteraction.updateSearchRequest = { [weak self] state in
            self?.searchState.set(state)
        }
        
        
        chatInteraction.focusMessageId = { [weak self] fromId, toId, state in
            
            if let strongSelf = self {
                if let fromId = fromId {
                    strongSelf.historyState = strongSelf.historyState.withAddingReply(fromId)
                }
                
                var fromIndex: MessageIndex?
                
                if let fromId = fromId, let message = strongSelf.messageInCurrentHistoryView(fromId) {
                    fromIndex = MessageIndex(message)
                } else {
                    if let message = strongSelf.anchorMessageInCurrentHistoryView() {
                        fromIndex = MessageIndex(message)
                    }
                }
                if let fromIndex = fromIndex {
//                    if let message = strongSelf.messageInCurrentHistoryView(toId) {
//                        strongSelf.genericView.tableView.scroll(to: state.swap(to: ChatHistoryEntryId.message(message)))
//                    } else {
                        let historyView = chatHistoryViewForLocation(.InitialSearch(location: .id(toId), count: 100), account: context.account, chatLocation: strongSelf.chatLocation, fixedCombinedReadStates: nil, tagMask: nil, additionalData: [])
                        
                        struct FindSearchMessage {
                            let message:Message?
                            let loaded:Bool
                        }

                    let signal = historyView
                        |> mapToSignal { historyView -> Signal<(Message?, Bool), NoError> in
                            switch historyView {
                            case .Loading:
                                return .single((nil, true))
                            case let .HistoryView(view, _, _, _):
                                for entry in view.entries {
                                    if entry.message.id == toId {
                                        return .single((entry.message, false))
                                    }
                                }
//                                if case let .index(index) = ChatHistoryInitialSearchLocation.id(toId) {
//                                    return .single((index, false))
//                                }
                                return .single((nil, false))
                            }
                        } |> take(until: { index in
                                return SignalTakeAction(passthrough: true, complete: !index.1)
                        }) |> map { $0.0 }

                        strongSelf.chatInteraction.loadingMessage.set(.single(true) |> delay(0.2, queue: Queue.mainQueue()))
                        strongSelf.messageIndexDisposable.set((signal |> deliverOnMainQueue).start(next: { [weak strongSelf] message in
                            self?.chatInteraction.loadingMessage.set(.single(false))
                            if let strongSelf = strongSelf, let message = message {
                                let toIndex = MessageIndex(message)
                                strongSelf.setLocation(.Scroll(index: MessageHistoryAnchorIndex.message(toIndex), anchorIndex: MessageHistoryAnchorIndex.message(toIndex), sourceIndex: MessageHistoryAnchorIndex.message(fromIndex), scrollPosition: state.swap(to: ChatHistoryEntryId.message(message)), count: strongSelf.requestCount, animated: state.animated))
                            }
                        }, completed: {
                                
                        }))
                  //  }
                }
                
            }
            
        }
        
        chatInteraction.vote = { [weak self] messageId, opaqueIdentifier in
            guard let `self` = self else {return}
            
            self.update { data -> [MessageId : Data] in
                var data = data
                if opaqueIdentifier == nil {
                    data.removeValue(forKey: messageId)
                } else {
                    data[messageId] = opaqueIdentifier
                }
                return data
            }
            
            let signal:Signal<Never, RequestMessageSelectPollOptionError>

            
            if opaqueIdentifier == nil {
                signal = showModalProgress(signal: (requestMessageSelectPollOption(account: context.account, messageId: messageId, opaqueIdentifier: opaqueIdentifier) |> deliverOnMainQueue), for: mainWindow)
            } else {
                signal = (requestMessageSelectPollOption(account: context.account, messageId: messageId, opaqueIdentifier: opaqueIdentifier) |> deliverOnMainQueue)
            }
            
            self.selectMessagePollOptionDisposables.set(signal.start(error: { error in
                switch error {
                case .generic:
                    alert(for: mainWindow, info: L10n.unknownError)
                }
            }, completed: { [weak self] in
                 self?.update { data -> [MessageId : Data] in
                    var data = data
                    data.removeValue(forKey: messageId)
                    return data
                }
                if let tableView = self?.genericView.tableView {
                    tableView.enumerateVisibleItems(with: { item -> Bool in
                        if let item = item as? ChatRowItem, item.message?.id == messageId {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
                            return false
                        }
                        return true
                    })
                }
            }), forKey: messageId)
        }
        chatInteraction.closePoll = { [weak self] messageId in
            guard let `self` = self else {return}
            self.selectMessagePollOptionDisposables.set(requestClosePoll(postbox: context.account.postbox, network: context.account.network, stateManager: context.account.stateManager, messageId: messageId).start(), forKey: messageId)
        }
        
        
        chatInteraction.sendMedia = { [weak self] media in
            if let strongSelf = self, let peer = strongSelf.chatInteraction.peer, peer.canSendMessage {
                let _ = (Sender.enqueue(media: media, context: context, peerId: strongSelf.chatInteraction.peerId, chatInteraction: strongSelf.chatInteraction) |> deliverOnMainQueue).start(completed: scrollAfterSend)
                strongSelf.nextTransaction.set(handler: {})
            }
        }
        
        chatInteraction.attachFile = { [weak self] asMedia in
            if let `self` = self, let window = self.window {
                filePanel(canChooseDirectories: true, for: window, completion:{ result in
                    if let result = result {
                        
                        let previous = result.count
                        
                        let result = result.filter { path -> Bool in
                            if let size = fs(path) {
                                return size <= 1500 * 1024 * 1024
                            }
                            return false
                        }
                        
                        let afterSizeCheck = result.count
                        
                        if afterSizeCheck == 0 && previous != afterSizeCheck {
                            alert(for: mainWindow, info: L10n.appMaxFileSize)
                        } else {
                            self.chatInteraction.showPreviewSender(result.map{URL(fileURLWithPath: $0)}, asMedia)
                        }
                        
                    }
                })
            }
            
        }
        chatInteraction.attachPhotoOrVideo = { [weak self] in
            if let `self` = self, let window = self.window {
                filePanel(with: mediaExts, canChooseDirectories: true, for: window, completion:{ [weak self] result in
                    if let result = result {
                        let previous = result.count
                        
                        let result = result.filter { path -> Bool in
                            if let size = fs(path) {
                                return size <= 1500 * 1024 * 1024
                            }
                            return false
                        }
                        
                        let afterSizeCheck = result.count
                        
                        if afterSizeCheck == 0 && previous != afterSizeCheck {
                            alert(for: mainWindow, info: L10n.appMaxFileSize)
                        } else {
                            self?.chatInteraction.showPreviewSender(result.map{URL(fileURLWithPath: $0)}, true)
                        }
                    }
                })
            }
        }
        chatInteraction.attachPicture = { [weak self] in
            guard let `self` = self else {return}
            if let window = self.window {
                pickImage(for: window, completion: { [weak self] image in
                    if let image = image {
                        self?.chatInteraction.mediaPromise.set(putToTemp(image: image) |> map({[MediaSenderContainer(path:$0)]}))
                    }
                })
            }
        }
        chatInteraction.attachLocation = { [weak self] in
            guard let `self` = self else {return}
            showModal(with: LocationModalController(self.chatInteraction), for: mainWindow)
        }
        
        chatInteraction.sendAppFile = { [weak self] file in
            if let strongSelf = self, let peer = strongSelf.chatInteraction.peer, peer.canSendMessage {
                let _ = (Sender.enqueue(media: file, context: context, peerId: strongSelf.chatInteraction.peerId, chatInteraction: strongSelf.chatInteraction) |> deliverOnMainQueue).start(completed: scrollAfterSend)
                strongSelf.nextTransaction.set(handler: {})
                
            }
        }
        
        chatInteraction.sendMedias = { [weak self] medias, caption, isCollage, additionText in
            if let strongSelf = self, let peer = strongSelf.chatInteraction.peer, peer.canSendMessage {
                let _ = (Sender.enqueue(media: medias, caption: caption, context: context, peerId: strongSelf.chatInteraction.peerId, chatInteraction: strongSelf.chatInteraction, isCollage: isCollage, additionText: additionText) |> deliverOnMainQueue).start(completed: scrollAfterSend)
                strongSelf.nextTransaction.set(handler: {})
                
            }
        }
        
        chatInteraction.shareSelfContact = { [weak self] replyId in
            if let strongSelf = self, let peer = strongSelf.chatInteraction.peer, peer.canSendMessage {
                strongSelf.shareContactDisposable.set((context.account.viewTracker.peerView(context.account.peerId) |> take(1)).start(next: { [weak strongSelf] peerView in
                    if let strongSelf = strongSelf, let peer = peerViewMainPeer(peerView) as? TelegramUser {
                        _ = Sender.enqueue(message: EnqueueMessage.message(text: "", attributes: [], mediaReference: AnyMediaReference.standalone(media: TelegramMediaContact(firstName: peer.firstName ?? "", lastName: peer.lastName ?? "", phoneNumber: peer.phone ?? "", peerId: peer.id, vCardData: nil)), replyToMessageId: replyId, localGroupingKey: nil), context: context, peerId: strongSelf.chatInteraction.peerId).start()
                    }
                }))
            }
        }
        
        chatInteraction.modalSearch = { [weak self] query in
            if let strongSelf = self {
                let apply = showModalProgress(signal: searchMessages(account: context.account, location: .peer(peerId: strongSelf.chatInteraction.peerId, fromId: nil, tags: nil), query: query, state: nil), for: mainWindow)
                showModal(with: SearchResultModalController(context, request: apply |> map {$0.0.messages}, query: query, chatInteraction:strongSelf.chatInteraction), for: mainWindow)
            }
        }
        
        chatInteraction.sendCommand = { [weak self] command in
            if let strongSelf = self, let peer = strongSelf.chatInteraction.peer, peer.canSendMessage {
                var commandText = "/" + command.command.text
                if strongSelf.chatInteraction.peerId.namespace != Namespaces.Peer.CloudUser {
                    commandText += "@" + (command.peer.username ?? "")
                }
                strongSelf.chatInteraction.updateInput(with: "")
                let _ = enqueueMessages(context: context, peerId: strongSelf.chatInteraction.peerId, messages: [EnqueueMessage.message(text: commandText, attributes:[], mediaReference: nil, replyToMessageId: nil, localGroupingKey: nil)]).start()
            }
        }
        
        chatInteraction.switchInlinePeer = { [weak self] switchId, initialAction in
            if let strongSelf = self {
                strongSelf.navigationController?.push(ChatSwitchInlineController(context: context, peerId: switchId, fallbackId:strongSelf.chatInteraction.peerId, initialAction: initialAction))
            }
        }
        
        chatInteraction.setNavigationAction = { [weak self] action in
            self?.navigationController?.set(modalAction: action)
        }
        
        chatInteraction.showPreviewSender = { [weak self] urls, asMedia in
            if let chatInteraction = self?.chatInteraction, let window = self?.navigationController?.window {
                showModal(with: PreviewSenderController(urls: urls, chatInteraction: chatInteraction, asMedia: asMedia), for: window)
            }
        }
        
        chatInteraction.setSecretChatMessageAutoremoveTimeout = { [weak self] seconds in
            if let strongSelf = self, let peer = strongSelf.chatInteraction.peer, peer.canSendMessage {
                _ = setSecretChatMessageAutoremoveTimeoutInteractively(account: context.account, peerId: strongSelf.chatInteraction.peerId, timeout:seconds).start()
            }
        }
        
        chatInteraction.toggleNotifications = { [weak self] in
            if let strongSelf = self {
                _ = togglePeerMuted(account: context.account, peerId: strongSelf.chatInteraction.peerId).start()
            }
        }
        
        chatInteraction.openDiscussion = { [weak self] in
            guard let `self` = self else { return }
            let signal = showModalProgress(signal: context.account.viewTracker.peerView(self.chatLocation.peerId) |> filter { $0.cachedData is CachedChannelData } |> map { $0.cachedData as! CachedChannelData } |> take(1) |> deliverOnMainQueue, for: context.window)
            self.discussionDataLoadDisposable.set(signal.start(next: { [weak self] cachedData in
                if let linkedDiscussionPeerId = cachedData.linkedDiscussionPeerId {
                    self?.chatInteraction.openInfo(linkedDiscussionPeerId, true, nil, nil)
                }
            }))
        }
        
        chatInteraction.removeAndCloseChat = { [weak self] in
            if let strongSelf = self, let window = strongSelf.window {
                _ = showModalProgress(signal: removePeerChat(account: context.account, peerId: strongSelf.chatInteraction.peerId, reportChatSpam: false), for: window).start(next: { [weak strongSelf] in
                    strongSelf?.navigationController?.close()
                })
            }
        }
        
        chatInteraction.removeChatInteractively = { [weak self] in
            if let strongSelf = self {
                let signal = removeChatInteractively(context: context, peerId: strongSelf.chatInteraction.peerId, userId: strongSelf.chatInteraction.peer?.id) |> filter {$0} |> mapToSignal { _ -> Signal<ChatLocation?, NoError> in
                    return context.globalPeerHandler.get() |> take(1)
                   } |> deliverOnMainQueue
                
                strongSelf.deleteChatDisposable.set(signal.start(next: { [weak strongSelf] location in
                    if location == strongSelf?.chatInteraction.chatLocation {
                        strongSelf?.context.sharedContext.bindings.rootNavigation().close()
                    }
                }))
            }
        }
        
        chatInteraction.joinChannel = { [weak self] in
            if let strongSelf = self, let window = strongSelf.window {
                _ = showModalProgress(signal: joinChannel(account: context.account, peerId: strongSelf.chatInteraction.peerId), for: window).start()
            }
        }
        
        chatInteraction.returnGroup = { [weak self] in
            if let strongSelf = self, let window = strongSelf.window {
                _ = showModalProgress(signal: returnGroup(account: context.account, peerId: strongSelf.chatInteraction.peerId), for: window).start()
            }
        }
        
        
        
        chatInteraction.shareContact = { [weak self] peer in
            if let strongSelf = self, let main = strongSelf.chatInteraction.peer, main.canSendMessage {
                _ = Sender.shareContact(context: context, peerId: strongSelf.chatInteraction.peerId, contact: peer).start()
            }
        }
        
        chatInteraction.unblock = { [weak self] in
            if let strongSelf = self {
                self?.unblockDisposable.set(requestUpdatePeerIsBlocked(account: context.account, peerId: strongSelf.chatInteraction.peerId, isBlocked: false).start())
            }
        }
        
        chatInteraction.updatePinned = { [weak self] pinnedId, dismiss, silent in
            if let `self` = self {
                
                let pinnedUpdate: PinnedMessageUpdate = dismiss ? .clear : .pin(id: pinnedId, silent: silent)
                let peerId = self.chatInteraction.peerId
                if let peer = self.chatInteraction.peer as? TelegramChannel {
                    if peer.hasPermission(.pinMessages) || (peer.isChannel && peer.hasPermission(.editAllMessages)) {
                        
                        self.updatePinnedDisposable.set(((dismiss ? confirmSignal(for: mainWindow, information: L10n.chatConfirmUnpin) : Signal<Bool, NoError>.single(true)) |> filter {$0} |> mapToSignal { _ in return
                            showModalProgress(signal: requestUpdatePinnedMessage(account: context.account, peerId: peerId, update: pinnedUpdate) |> `catch` {_ in .complete()
                        }, for: mainWindow)}).start())
                    } else {
                        self.chatInteraction.update({$0.updatedInterfaceState({$0.withUpdatedDismissedPinnedId(pinnedId)})})
                    }
                } else if self.chatInteraction.peerId == context.peerId {
                    if dismiss {
                        confirm(for: mainWindow, information: L10n.chatConfirmUnpin, successHandler: { _ in
                            self.updatePinnedDisposable.set(showModalProgress(signal: requestUpdatePinnedMessage(account: context.account, peerId: peerId, update: pinnedUpdate), for: mainWindow).start())
                        })
                    } else {
                        self.updatePinnedDisposable.set(showModalProgress(signal: requestUpdatePinnedMessage(account: context.account, peerId: peerId, update: pinnedUpdate), for: mainWindow).start())
                    }
                } else if let peer = self.chatInteraction.peer as? TelegramGroup, peer.canPinMessage {
                    if dismiss {
                        confirm(for: mainWindow, information: L10n.chatConfirmUnpin, successHandler: { _ in
                            self.updatePinnedDisposable.set(showModalProgress(signal: requestUpdatePinnedMessage(account: context.account, peerId: peerId, update: pinnedUpdate), for: mainWindow).start())
                        })
                    } else {
                        self.updatePinnedDisposable.set(showModalProgress(signal: requestUpdatePinnedMessage(account: context.account, peerId: peerId, update: pinnedUpdate), for: mainWindow).start())
                    }
                }
            }
        }
        
        chatInteraction.reportSpamAndClose = { [weak self] in
            if let strongSelf = self {
                
                let title: String
                if let peer = strongSelf.chatInteraction.peer {
                    if peer.isUser {
                        title = L10n.chatConfirmReportSpamUser
                    } else if peer.isChannel {
                        title = L10n.chatConfirmReportSpamChannel
                    } else if peer.isGroup || peer.isSupergroup {
                        title = L10n.chatConfirmReportSpamGroup
                    } else {
                        title = L10n.chatConfirmReportSpam
                    }
                } else {
                    title = L10n.chatConfirmReportSpam
                }
                
                
                
                
                strongSelf.reportPeerDisposable.set((confirmSignal(for: mainWindow, header: appName, information: title, okTitle: L10n.modalOK, cancelTitle: L10n.modalCancel) |> filter {$0} |> mapToSignal { _ in
                    return reportPeer(account: context.account, peerId: strongSelf.chatInteraction.peerId) |> deliverOnMainQueue |> mapToSignal { [weak strongSelf] () -> Signal<Void, NoError> in
                        if let strongSelf = strongSelf, let peer = strongSelf.chatInteraction.peer {
                            if peer.id.namespace == Namespaces.Peer.CloudUser {
                                return requestUpdatePeerIsBlocked(account: context.account, peerId: peer.id, isBlocked: true) |> deliverOnMainQueue |> mapToSignal { [weak strongSelf] () -> Signal<Void, NoError> in
                                    if let strongSelf = strongSelf {
                                        return removePeerChat(account: context.account, peerId: strongSelf.chatInteraction.peerId, reportChatSpam: false)
                                    }
                                    return .complete()
                                }
                            } else {
                                return removePeerChat(account: context.account, peerId: strongSelf.chatInteraction.peerId, reportChatSpam: true)
                            }
                        }
                        return .complete()
                    } |> map { _ in return true} |> deliverOnMainQueue
                }).start(next: { [weak strongSelf] result in
                    if let strongSelf = strongSelf, result {
                        strongSelf.navigationController?.back()
                    }
                }))
            }
        }
        
        chatInteraction.dismissPeerReport = { [weak self] in
            if let strongSelf = self {
                _ = dismissReportPeer(account: context.account, peerId: strongSelf.chatInteraction.peerId).start()
            }
        }
        
        chatInteraction.toggleSidebar = { [weak self] in
            FastSettings.toggleSidebarShown(!FastSettings.sidebarShown)
            self?.updateSidebar()
            (self?.navigationController as? MajorNavigationController)?.genericView.update()
        }
        
        chatInteraction.focusInputField = { [weak self] in
            _ = self?.context.window.makeFirstResponder(self?.firstResponder())
        }

        let initialData = initialDataHandler.get() |> take(1) |> beforeNext { [weak self] (combinedInitialData) in
            
            if let `self` = self {
                if let initialData = combinedInitialData.initialData {
                    if let interfaceState = initialData.chatInterfaceState as? ChatInterfaceState {
                        self.chatInteraction.update(animated:false,{$0.updatedInterfaceState({_ in return interfaceState})})
                    }
                    self.chatInteraction.invokeInitialAction(includeAuto: true, animated: false)
                    
                    
                    
                    self.chatInteraction.update(animated:false,{ present in
                        var present = present
                        if let cachedData = combinedInitialData.cachedData as? CachedUserData {
                            present = present.withUpdatedBlocked(cachedData.isBlocked).withUpdatedReportStatus(cachedData.reportStatus).withUpdatedPinnedMessageId(cachedData.pinnedMessageId)
                        } else if let cachedData = combinedInitialData.cachedData as? CachedChannelData {
                            present = present.withUpdatedReportStatus(cachedData.reportStatus).withUpdatedPinnedMessageId(cachedData.pinnedMessageId).withUpdatedIsNotAccessible(cachedData.isNotAccessible)
                        } else if let cachedData = combinedInitialData.cachedData as? CachedGroupData {
                            present = present.withUpdatedReportStatus(cachedData.reportStatus).withUpdatedPinnedMessageId(cachedData.pinnedMessageId)
                        } else if let cachedData = combinedInitialData.cachedData as? CachedSecretChatData {
                            present = present.withUpdatedReportStatus(cachedData.reportStatus)
                        } else {
                            present = present.withUpdatedPinnedMessageId(nil)
                        }
                        if let messageId = present.pinnedMessageId {
                            present = present.withUpdatedCachedPinnedMessage(combinedInitialData.cachedDataMessages?[messageId])
                        }
                        return present.withUpdatedLimitConfiguration(combinedInitialData.limitsConfiguration)
                    })
                   
                    
                    if let modalAction = self.navigationController?.modalAction {
                        self.invokeNavigation(action: modalAction)
                    }
                    
                    
                    self.state = self.chatInteraction.presentation.state == .selecting ? .Edit : .Normal
                    self.notify(with: self.chatInteraction.presentation, oldValue: ChatPresentationInterfaceState(self.chatInteraction.chatLocation), animated: false, force: true)
                    
                    self.genericView.inputView.updateInterface(with: self.chatInteraction)
                }
            }
            
            } |> map {_ in}
        
        let first:Atomic<Bool> = Atomic(value: true)
        

        
        peerDisposable.set((peerView.get()
            |> deliverOnMainQueue |> beforeNext  { [weak self] postboxView in
                
                guard let `self` = self else {return}
                
                (self.centerBarView as? ChatTitleBarView)?.postboxView = postboxView
                
                switch self.chatLocation {
                case .peer:
                    let peerView = postboxView as? PeerView
                    
                    if let cachedData = peerView?.cachedData as? CachedChannelData {
                        let onlineMemberCount:Signal<Int32?, NoError>
                        if (cachedData.participantsSummary.memberCount ?? 0) > 200 {
                            onlineMemberCount = context.peerChannelMemberCategoriesContextsManager.recentOnline(postbox: context.account.postbox, network: context.account.network, accountPeerId: context.peerId, peerId: chatInteraction.peerId)  |> map(Optional.init) |> deliverOnMainQueue
                        } else {
                            onlineMemberCount = context.peerChannelMemberCategoriesContextsManager.recentOnlineSmall(postbox: context.account.postbox, network: context.account.network, accountPeerId: context.peerId, peerId: chatInteraction.peerId)  |> map(Optional.init) |> deliverOnMainQueue
                        }
                        
                        self.onlineMemberCountDisposable.set(onlineMemberCount.start(next: { [weak self] count in
                            (self?.centerBarView as? ChatTitleBarView)?.onlineMemberCount = count
                        }))
                    }
                    
                    
                    
                    self.chatInteraction.update(animated: !first.swap(false), { [weak peerView] presentation in
                        if let peerView = peerView {
                            
                            
                            
                            var present = presentation.updatedPeer { [weak peerView] _ in
                                if let peerView = peerView {
                                    return peerView.peers[peerView.peerId]
                                }
                                return nil
                            }.updatedMainPeer(peerViewMainPeer(peerView))
                            
                            var discussionGroupId:PeerId? = nil
                            if let cachedData = peerView.cachedData as? CachedChannelData, let linkedDiscussionPeerId = cachedData.linkedDiscussionPeerId {
                                if let peer = peerViewMainPeer(peerView) as? TelegramChannel {
                                    switch peer.info {
                                    case let .broadcast(info):
                                        if info.flags.contains(.hasDiscussionGroup) {
                                            discussionGroupId = linkedDiscussionPeerId
                                        }
                                    default:
                                        break
                                    }
                                }
                            }
                            
                            present = present.withUpdatedDiscussionGroupId(discussionGroupId)
                            
                            if let cachedData = peerView.cachedData as? CachedUserData {
                                present = present.withUpdatedBlocked(cachedData.isBlocked).withUpdatedReportStatus(cachedData.reportStatus).withUpdatedPinnedMessageId(cachedData.pinnedMessageId)
                            } else if let cachedData = peerView.cachedData as? CachedChannelData {
                                present = present.withUpdatedReportStatus(cachedData.reportStatus).withUpdatedPinnedMessageId(cachedData.pinnedMessageId).withUpdatedIsNotAccessible(cachedData.isNotAccessible)
                            } else if let cachedData = peerView.cachedData as? CachedGroupData {
                                present = present.withUpdatedReportStatus(cachedData.reportStatus).withUpdatedPinnedMessageId(cachedData.pinnedMessageId)
                            } else if let cachedData = peerView.cachedData as? CachedSecretChatData {
                                present = present.withUpdatedReportStatus(cachedData.reportStatus)
                            }
                            
                            var canAddContact:Bool? = nil
                            if let peer = peerViewMainPeer(peerView) as? TelegramUser {
                                if let _ = peer.phone, !peerView.peerIsContact {
                                    canAddContact = true
                                }
                            }
                            present = present.withUpdatedContactAdding(canAddContact)
                            
                            if let notificationSettings = peerView.notificationSettings as? TelegramPeerNotificationSettings {
                                present = present.updatedNotificationSettings(notificationSettings)
                            }
                            return present
                        }
                        return presentation
                    })
                }
                
                
            }).start())
        
        
        
        if chatInteraction.peerId.namespace == Namespaces.Peer.CloudChannel {
            let (recentDisposable, _) = context.peerChannelMemberCategoriesContextsManager.recent(postbox: context.account.postbox, network: context.account.network, accountPeerId: context.peerId, peerId: chatInteraction.peerId, updated: { _ in })
            let (adminsDisposable, _) = context.peerChannelMemberCategoriesContextsManager.admins(postbox: context.account.postbox, network: context.account.network, accountPeerId: context.peerId, peerId: chatInteraction.peerId, updated: { _ in })
            let disposable = DisposableSet()
            disposable.add(recentDisposable)
            disposable.add(adminsDisposable)
            
            updatedChannelParticipants.set(disposable)
        }
        
        let connectionStatus = combineLatest(context.account.network.connectionStatus |> delay(0.5, queue: Queue.mainQueue()), context.account.stateManager.isUpdating |> delay(0.5, queue: Queue.mainQueue())) |> deliverOnMainQueue |> beforeNext { [weak self] status, isUpdating -> Void in
            var status = status
            switch status {
            case let .online(proxyAddress):
                if isUpdating {
                    status = .updating(proxyAddress: proxyAddress)
                }
            default:
                break
            }
            
            (self?.centerBarView as? ChatTitleBarView)?.connectionStatus = status
        }
        
        let combine = combineLatest(_historyReady.get() |> deliverOnMainQueue , peerView.get() |> deliverOnMainQueue |> take(1) |> map {_ in} |> then(initialData), genericView.inputView.ready.get())
        
        
        //self.ready.set(.single(true))
        
        self.ready.set(combine |> map { (hReady, _, iReady) in
            return hReady && iReady
        })
        
        
        connectionStatusDisposable.set((connectionStatus).start())
        
        
        var beginPendingTime:CFAbsoluteTime?
        
        
        switch chatLocation {
        case let .peer(peerId):
            self.sentMessageEventsDisposable.set((context.account.pendingMessageManager.deliveredMessageEvents(peerId: peerId)).start(next: { _ in
                
                if FastSettings.inAppSounds {
                    let afterSentSound:NSSound? = {
                        
                        let p = Bundle.main.path(forResource: "sent", ofType: "caf")
                        var sound:NSSound?
                        if let p = p {
                            sound = NSSound(contentsOfFile: p, byReference: true)
                            sound?.volume = 1.0
                        }
                        
                        return sound
                    }()
                    
                    if let beginPendingTime = beginPendingTime {
                        if CFAbsoluteTimeGetCurrent() - beginPendingTime < 0.5 {
                            return
                        }
                    }
                    beginPendingTime = CFAbsoluteTimeGetCurrent()
                    afterSentSound?.play()
                }
            }))
            
            botCallbackAlertMessageDisposable = (self.botCallbackAlertMessage.get()
                |> deliverOnMainQueue).start(next: { [weak self] (message, isAlert) in
                   
                    if let strongSelf = self, let message = message {
                        if !message.isEmpty {
                            if isAlert {
                                alert(for: mainWindow, info: message)
                            } else {
                                strongSelf.show(toaster: ControllerToaster(text:.initialize(string: message.fixed, color: theme.colors.text, font: .normal(.text))))
                            }
                        } else {
                            strongSelf.removeToaster()
                        }
                    }
                    
                })
            
            
            self.chatUnreadMentionCountDisposable.set((context.account.viewTracker.unseenPersonalMessagesCount(peerId: peerId) |> deliverOnMainQueue).start(next: { [weak self] count in
                self?.genericView.updateMentionsCount(count, animated: true)
            }))
            
            let previousPeerCache = Atomic<[PeerId: Peer]>(value: [:])
            self.peerInputActivitiesDisposable.set((context.account.peerInputActivities(peerId: peerId)
                |> mapToSignal { activities -> Signal<[(Peer, PeerInputActivity)], NoError> in
                    var foundAllPeers = true
                    var cachedResult: [(Peer, PeerInputActivity)] = []
                    previousPeerCache.with { dict -> Void in
                        for (peerId, activity) in activities {
                            if let peer = dict[peerId] {
                                cachedResult.append((peer, activity))
                            } else {
                                foundAllPeers = false
                                break
                            }
                        }
                    }
                    if foundAllPeers {
                        return .single(cachedResult)
                    } else {
                        return context.account.postbox.transaction { transaction -> [(Peer, PeerInputActivity)] in
                            var result: [(Peer, PeerInputActivity)] = []
                            var peerCache: [PeerId: Peer] = [:]
                            for (peerId, activity) in activities {
                                if let peer = transaction.getPeer(peerId) {
                                    result.append((peer, activity))
                                    peerCache[peerId] = peer
                                }
                            }
                            _ = previousPeerCache.swap(peerCache)
                            return result
                        }
                    }
                }
                |> deliverOnMainQueue).start(next: { [weak self] activities in
                    if let strongSelf = self, strongSelf.chatInteraction.peerId != strongSelf.context.peerId {
                        (strongSelf.centerBarView as? ChatTitleBarView)?.inputActivities = (strongSelf.chatInteraction.peerId, activities)
                    }
                }))
            
        default:
            break
        }
        
        
       
        
        
        
       // var beginHistoryTime:CFAbsoluteTime?

        genericView.tableView.setScrollHandler({ [weak self] scroll in
            guard let `self` = self else {return}
            let view = self.previousView.with {$0?.originalView}
            if let view = view {
                var messageIndex:MessageIndex?

                
                let visible = self.genericView.tableView.visibleRows()

                
                
                switch scroll.direction {
                case .top:
                    if view.laterId != nil {
                        for i in visible.min ..< visible.max {
                            if let item = self.genericView.tableView.item(at: i) as? ChatRowItem {
                                messageIndex = item.entry.index
                                break
                            }
                        }
                    } else if view.laterId == nil, !view.holeLater, let locationValue = self.locationValue, !locationValue.isAtUpperBound, view.anchorIndex != .upperBound {
                        messageIndex = .upperBound(peerId: self.chatInteraction.peerId)
                    }
                case .bottom:
                    if view.earlierId != nil {
                        for i in stride(from: visible.max - 1, to: -1, by: -1) {
                            if let item = self.genericView.tableView.item(at: i) as? ChatRowItem {
                                messageIndex = item.entry.index
                                break
                            }
                        }
                    }
                case .none:
                    break
                }
                if let messageIndex = messageIndex {
                    let location: ChatHistoryLocation = .Navigation(index: MessageHistoryAnchorIndex.message(messageIndex), anchorIndex: MessageHistoryAnchorIndex.message(messageIndex), count: 100, side: scroll.direction == .bottom ? .upper : .lower)
                    self.setLocation(location)
                }
            }
            
        })
        
        genericView.tableView.addScroll(listener: TableScrollListener(dispatchWhenVisibleRangeUpdated: false, { [weak self] _ in
            guard let `self` = self else {return}
            self.updateInteractiveReading()
        }))
        
        genericView.tableView.addScroll(listener: TableScrollListener { [weak self] position in
            let tableView = self?.genericView.tableView
            
            if let strongSelf = self, let tableView = tableView {
            
                if let row = tableView.topVisibleRow, let item = tableView.item(at: row) as? ChatRowItem, let id = item.message?.id {
                    strongSelf.historyState = strongSelf.historyState.withRemovingReplies(max: id)
                }
                
                var message:Message? = nil
                
                var messageIdsWithViewCount: [MessageId] = []
                var messageIdsWithUnseenPersonalMention: [MessageId] = []
                var unsupportedMessagesIds: [MessageId] = []
                tableView.enumerateVisibleItems(with: { item in
                    if let item = item as? ChatRowItem {
                        if message == nil {
                            message = item.messages.last
                        }
                        
                        for message in item.messages {
                            var hasUncocumedMention: Bool = false
                            var hasUncosumedContent: Bool = false
                            
                            if message.tags.contains(.unseenPersonalMessage) {
                                for attribute in message.attributes {
                                    if let attribute = attribute as? ConsumableContentMessageAttribute, !attribute.consumed {
                                        hasUncosumedContent = true
                                    }
                                    if let attribute = attribute as? ConsumablePersonalMentionMessageAttribute, !attribute.pending {
                                        hasUncocumedMention = true
                                    }
                                }
                                if hasUncocumedMention && !hasUncosumedContent {
                                    messageIdsWithUnseenPersonalMention.append(message.id)
                                }
                            }
                            inner: for attribute in message.attributes {
                                if attribute is ViewCountMessageAttribute {
                                    messageIdsWithViewCount.append(message.id)
                                    break inner
                                }
                            }
                            if message.media.first is TelegramMediaUnsupported {
                                unsupportedMessagesIds.append(message.id)
                            }
                        }
                        
                        
                    }
                    return true
                })
                
                
              
                
                if !messageIdsWithViewCount.isEmpty {
                    strongSelf.messageProcessingManager.add(messageIdsWithViewCount)
                }
                
                if !messageIdsWithUnseenPersonalMention.isEmpty {
                    strongSelf.messageMentionProcessingManager.add(messageIdsWithUnseenPersonalMention)
                }
                if !unsupportedMessagesIds.isEmpty {
                    strongSelf.unsupportedMessageProcessingManager.add(unsupportedMessagesIds)
                }
                
                if let message = message {
                    strongSelf.updateMaxVisibleReadIncomingMessageIndex(MessageIndex(message))
                }
                
               
            }
        })
        
        
   
        
        let undoSignals = combineLatest(queue: .mainQueue(), context.chatUndoManager.status(for: chatInteraction.peerId, type: .deleteChat), context.chatUndoManager.status(for: chatInteraction.peerId, type: .leftChat), context.chatUndoManager.status(for: chatInteraction.peerId, type: .leftChannel), context.chatUndoManager.status(for: chatInteraction.peerId, type: .deleteChannel))
        
        chatUndoDisposable.set(undoSignals.start(next: { [weak self] statuses in
            let result: [ChatUndoActionStatus?] = [statuses.0, statuses.1, statuses.2, statuses.3]
            for status in result {
                if let status = status, status != .cancelled {
                    self?.navigationController?.close()
                    break
                }
            }
        }))
        
    }
    
    override func navigationHeaderDidNoticeAnimation(_ current: CGFloat, _ previous: CGFloat, _ animated: Bool) -> ()->Void  {
        return genericView.navigationHeaderDidNoticeAnimation(current, previous, animated)
    }

    
    @available(OSX 10.12.2, *)
    override func makeTouchBar() -> NSTouchBar? {
        if let temporaryTouchBar = temporaryTouchBar as? ChatTouchBar {
            temporaryTouchBar.updateChatInteraction(self.chatInteraction, textView: self.genericView.inputView.textView.inputView)
        } else {
            temporaryTouchBar = ChatTouchBar(chatInteraction: self.chatInteraction, textView: self.genericView.inputView.textView.inputView)
        }
        return temporaryTouchBar as? NSTouchBar
    }
    
    override func windowDidBecomeKey() {
        super.windowDidBecomeKey()
        if #available(OSX 10.12.2, *) {
            (temporaryTouchBar as? ChatTouchBar)?.updateByKeyWindow()
        }
        updateInteractiveReading()
        chatInteraction.saveState(scrollState: immediateScrollState())
    }
    override func windowDidResignKey() {
        super.windowDidResignKey()
        if #available(OSX 10.12.2, *) {
            (temporaryTouchBar as? ChatTouchBar)?.updateByKeyWindow()
        }
        updateInteractiveReading()
        chatInteraction.saveState(scrollState:immediateScrollState())
    }
    
    private func anchorMessageInCurrentHistoryView() -> Message? {
        if let historyView = self.previousView.modify({$0}) {
            let visibleRange = self.genericView.tableView.visibleRows()
            var index = 0
            for entry in historyView.filteredEntries.reversed() {
                if index >= visibleRange.min && index <= visibleRange.max {
                    if case let .MessageEntry(message, _, _, _, _, _, _, _, _) = entry.entry {
                        return message
                    }
                }
                index += 1
            }
            
            for entry in historyView.filteredEntries {
                if let message = entry.appearance.entry.message {
                    return message
                }
            }
        }
        return nil
    }
    
    private func updateInteractiveReading() {
        let scroll = genericView.tableView.scrollPosition().current
        let hasEntries = (self.previousView.with { $0 }?.filteredEntries.count ?? 0) > 1
        if let window = window, window.isKeyWindow, self.historyState.isDownOfHistory && scroll.rect.minY == genericView.tableView.frame.height, hasEntries {
            self.interactiveReadingDisposable.set(installInteractiveReadMessagesAction(postbox: context.account.postbox, stateManager: context.account.stateManager, peerId: chatInteraction.peerId))
        } else {
            self.interactiveReadingDisposable.set(nil)
        }
    }
    
    
    
    private func messageInCurrentHistoryView(_ id: MessageId) -> Message? {
        if let historyView = self.previousView.modify({$0}) {
            for entry in historyView.filteredEntries {
                if let message = entry.appearance.entry.message, message.id == id {
                    return message
                }
            }
        }
        return nil
    }
    

    func applyTransition(_ transition:TableUpdateTransition, view: MessageHistoryView?, initialData:ChatHistoryCombinedInitialData, isLoading: Bool) {
        
        let wasEmpty = genericView.tableView.isEmpty

        initialDataHandler.set(.single(initialData))
        
        historyState = historyState.withUpdatedStateOfHistory(view?.laterId == nil)
        
        let oldState = genericView.state
        
        genericView.change(state: isLoading ? .progress : .visible, animated: view != nil)
      
        genericView.tableView.merge(with: transition)
        
        let _ = nextTransaction.execute()

        
        if oldState != genericView.state {
            genericView.tableView.updateEmpties(animated: view != nil)
        }
        
        genericView.tableView.notifyScrollHandlers()
        
        
        
        if let view = view, !view.entries.isEmpty {
            
           let tableView = genericView.tableView
            if !tableView.isEmpty {
                
                var earliest:Message?
                var latest:Message?
                self.genericView.tableView.enumerateVisibleItems(reversed: true, with: { item -> Bool in
                    
                    if let item = item as? ChatRowItem {
                        earliest = item.message
                    }
                    return earliest == nil
                })
                
                self.genericView.tableView.enumerateVisibleItems { item -> Bool in
                    
                    if let item = item as? ChatRowItem {
                        latest = item.message
                    }
                    return latest == nil
                }
            }
            
        } else if let peer = chatInteraction.peer, peer.isBot {
            if chatInteraction.presentation.initialAction == nil && self.genericView.state == .visible {
                chatInteraction.update(animated: false, {$0.updatedInitialAction(ChatInitialAction.start(parameter: "", behavior: .none))})
            }
        }
        chatInteraction.update(animated: !wasEmpty, { current in
            var current = current.updatedHistoryCount(genericView.tableView.count - 1).updatedKeyboardButtonsMessage(initialData.buttonKeyboardMessage)
            
            if let message = initialData.buttonKeyboardMessage, let replyMarkup = message.replyMarkup {
                if replyMarkup.flags.contains(.setupReply) {
                    if message.id != current.interfaceState.dismissedForceReplyId {
                        current = current.updatedInterfaceState({$0.withUpdatedReplyMessageId(message.id)})
                    }
                }
            }
            
            return current
        })
        
        readyHistory()
        
        updateInteractiveReading()
        
        self.context.sharedContext.bindings.entertainment().update(with: self.chatInteraction)
        
        self.centerBarView.animates = true
    }
    
    override func getCenterBarViewOnce() -> TitledBarView {
        return ChatTitleBarView(controller: self, chatInteraction)
    }
    
    private var editButton:ImageButton? = nil
    private var doneButton:TitleButton? = nil
    
    override func requestUpdateRightBar() {
        super.requestUpdateRightBar()
        editButton?.style = navigationButtonStyle
        editButton?.set(image: theme.icons.chatActions, for: .Normal)
        editButton?.set(image: theme.icons.chatActionsActive, for: .Highlight)

        editButton?.setFrameSize(70, 50)
        editButton?.center()
        doneButton?.set(color: theme.colors.blueUI, for: .Normal)
        doneButton?.style = navigationButtonStyle
    }
    
    
    override func getRightBarViewOnce() -> BarView {
        let back = BarView(70, controller: self) //MajorBackNavigationBar(self, account: account, excludePeerId: peerId)
        
        let editButton = ImageButton()
        editButton.disableActions()
        back.addSubview(editButton)
        
        self.editButton = editButton
//        
        let doneButton = TitleButton()
        doneButton.disableActions()
        doneButton.set(font: .medium(.text), for: .Normal)
        doneButton.set(text: tr(L10n.navigationDone), for: .Normal)
        _ = doneButton.sizeToFit()
        back.addSubview(doneButton)
        doneButton.center()
        
        self.doneButton = doneButton

        
        doneButton.isHidden = true
        
        doneButton.userInteractionEnabled = false
        editButton.userInteractionEnabled = false
        
        back.set(handler: { [weak self] _ in
            if let window = self?.window, !hasPopover(window) {
                self?.showRightControls()
            }
        }, for: .Click)
        requestUpdateRightBar()
        return back
    }

    private func showRightControls() {
        switch state {
        case .Normal:
            if let button = editButton {
                
                let context = self.context
                
                showRightControlsDisposable.set((peerView.get() |> take(1) |> deliverOnMainQueue).start(next: { [weak self] view in
                    guard let `self` = self else {return}
                    var items:[SPopoverItem] = []

                    switch self.chatLocation {
                    case let .peer(peerId):
                        guard let peerView = view as? PeerView else {return}
                        
                        items.append(SPopoverItem(tr(L10n.chatContextEdit1) + (FastSettings.tooltipAbility(for: .edit) ? " (\(L10n.chatContextEditHelp))" : ""),  { [weak self] in
                            self?.changeState()
                        }, theme.icons.chatActionEdit))
                        
                  
                        items.append(SPopoverItem(L10n.chatContextSharedMedia,  { [weak self] in
                            guard let `self` = self else {return}
                            self.navigationController?.push(PeerMediaController(context: self.context, peerId: self.chatInteraction.peerId, tagMask: .photoOrVideo))
                        }, theme.icons.chatAttachPhoto))
                        
                        items.append(SPopoverItem(L10n.chatContextInfo,  { [weak self] in
                            self?.chatInteraction.openInfo(peerId, false, nil, nil)
                        }, theme.icons.chatActionInfo))
                        
                        if let notificationSettings = peerView.notificationSettings as? TelegramPeerNotificationSettings, !self.isAdChat  {
                            if self.chatInteraction.peerId != context.peerId {
                                items.append(SPopoverItem(!notificationSettings.isMuted ? L10n.chatContextEnableNotifications : L10n.chatContextDisableNotifications, { [weak self] in
                                    self?.chatInteraction.toggleNotifications()
                                }, !notificationSettings.isMuted ? theme.icons.chatActionUnmute : theme.icons.chatActionMute))
                            }
                        }
                        
                        if let peer = peerViewMainPeer(peerView) {
                            
                            if let groupId = peerView.groupId, groupId != .root {
                                items.append(SPopoverItem(L10n.chatContextUnarchive, {
                                    _ = updatePeerGroupIdInteractively(postbox: context.account.postbox, peerId: peerId, groupId: .root).start()
                                }, theme.icons.chatUnarchive))
                            } else {
                                items.append(SPopoverItem(L10n.chatContextArchive, {
                                    _ = updatePeerGroupIdInteractively(postbox: context.account.postbox, peerId: peerId, groupId: Namespaces.PeerGroup.archive).start()
                                }, theme.icons.chatArchive))
                            }
                            
                            if peer.isGroup || peer.isUser || (peer.isSupergroup && peer.addressName == nil) {
                                items.append(SPopoverItem(L10n.chatContextClearHistory, {
                                    
                                    var thridTitle: String? = nil
                                    
                                    var canRemoveGlobally: Bool = false
                                    if peerId.namespace == Namespaces.Peer.CloudUser && peerId != context.account.peerId && !peer.isBot {
                                        if context.limitConfiguration.maxMessageRevokeIntervalInPrivateChats == LimitsConfiguration.timeIntervalForever {
                                            canRemoveGlobally = true
                                        }
                                    }
                                    
                                    if canRemoveGlobally {
                                        thridTitle = L10n.chatMessageDeleteForMeAndPerson(peer.displayTitle)
                                    }
                                    
                                    modernConfirm(for: mainWindow, account: context.account, peerId: peer.id, information: peer is TelegramUser ? peer.id == context.peerId ? L10n.peerInfoConfirmClearHistorySavedMesssages : canRemoveGlobally ? L10n.peerInfoConfirmClearHistoryUserBothSides : L10n.peerInfoConfirmClearHistoryUser : L10n.peerInfoConfirmClearHistoryGroup, okTitle: L10n.peerInfoConfirmClear, thridTitle: thridTitle, thridAutoOn: false, successHandler: { result in
                                        context.chatUndoManager.add(action: ChatUndoAction(peerId: peerId, type: .clearHistory, action: { status in
                                            switch status {
                                            case .success:
                                                context.chatUndoManager.clearHistoryInteractively(postbox: context.account.postbox, peerId: peerId, type: result == .thrid ? .forEveryone : .forLocalPeer)
                                                // _ = clearHistoryInteractively(postbox: account.postbox, peerId: peerId).start()
                                                break
                                            default:
                                                break
                                            }
                                        }))
                                       
                                    })
                                }, theme.icons.chatActionClearHistory))
                            }
                            
                            let deleteChat = { [weak self] in
                                guard let `self` = self else {return}
                                let signal = removeChatInteractively(context: context, peerId: self.chatInteraction.peerId, userId: self.chatInteraction.peer?.id) |> filter {$0} |> mapToSignal { _ -> Signal<ChatLocation?, NoError> in
                                    return context.globalPeerHandler.get() |> take(1)
                                } |> deliverOnMainQueue
                                
                                self.deleteChatDisposable.set(signal.start(next: { [weak self] location in
                                    if location == self?.chatInteraction.chatLocation {
                                        self?.context.sharedContext.bindings.rootNavigation().close()
                                    }
                                }))
                            }
                            
                            let text: String
                            if peer.isGroup {
                                text = L10n.chatListContextDeleteAndExit
                            } else if peer.isChannel {
                                text = L10n.chatListContextLeaveChannel
                            } else if peer.isSupergroup {
                                text = L10n.chatListContextLeaveGroup
                            } else {
                                text = L10n.chatListContextDeleteChat
                            }
                            
                            
                            items.append(SPopoverItem(text, deleteChat, theme.icons.chatActionDeleteChat))
                            
                        }
                    }
                    
                    
                    
                    showPopover(for: button, with: SPopoverViewController(items: items, visibility: 10), edge: .maxY, inset: NSMakePoint(0, -65))
                }))
                
                
            }
        case .Edit:
            changeState()
        case .Some:
            break
        }
    }
    
    override func getLeftBarViewOnce() -> BarView {
        let back = BarView(20, controller: self) //MajorBackNavigationBar(self, account: account, excludePeerId: peerId)
        back.set(handler: { [weak self] _ in
            self?.navigationController?.back()
        }, for: .Click)
        return back
    }
    
//    override func invokeNavigationBack() -> Bool {
//        return !context.closeFolderFirst
//    }
    
    override func escapeKeyAction() -> KeyHandlerResult {
        
//
//        if context.closeFolderFirst {
//            return .rejected
//        }
        
        if genericView.inputView.textView.inputView.hasMarkedText() {
            return .invokeNext
        }
        
        var result:KeyHandlerResult = .rejected
        if chatInteraction.presentation.state == .selecting {
            self.changeState()
            result = .invoked
        } else if chatInteraction.presentation.state == .editing {
            editMessageDisposable.set(nil)
            chatInteraction.update({$0.withoutEditMessage().updatedUrlPreview(nil)})
            result = .invoked
        } else if case let .contextRequest(request) = chatInteraction.presentation.inputContext {
            if request.query.isEmpty {
                chatInteraction.clearInput()
            } else {
                chatInteraction.clearContextQuery()
            }
            result = .invoked
        } else if chatInteraction.presentation.isSearchMode.0 {
            chatInteraction.update({$0.updatedSearchMode((false, nil))})
            result = .invoked
        } else if chatInteraction.presentation.recordingState != nil {
            chatInteraction.update({$0.withoutRecordingState()})
            return .invoked
        } else if chatInteraction.presentation.interfaceState.replyMessageId != nil {
            chatInteraction.update({$0.updatedInterfaceState({$0.withUpdatedReplyMessageId(nil)})})
            return .invoked
        }
        
        return result
    }
    
    override func backKeyAction() -> KeyHandlerResult {
        
        if hasModals() {
            return .invokeNext
        }
        if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
            if !selectManager.isEmpty {
                _ = selectManager.selectPrevChar()
                return .invoked
            }
        }
        
        return !self.chatInteraction.presentation.isSearchMode.0 && self.chatInteraction.presentation.effectiveInput.inputText.isEmpty ? .rejected : .invokeNext
    }
    
    override func returnKeyAction() -> KeyHandlerResult {
        if let recordingState = chatInteraction.presentation.recordingState {
            recordingState.stop()
            chatInteraction.mediaPromise.set(recordingState.data)
            closeAllModals()
            chatInteraction.update({$0.withoutRecordingState()})
            return .invoked
        }
        return super.returnKeyAction()
    }
    
    override func nextKeyAction() -> KeyHandlerResult {
        
        if hasModals() {
            return .invokeNext
        }
        
        if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
            if !selectManager.isEmpty {
                _ = selectManager.selectNextChar()
                return .invoked
            }
        }
        
        if !self.chatInteraction.presentation.isSearchMode.0 && chatInteraction.presentation.effectiveInput.inputText.isEmpty {
            chatInteraction.openInfo(chatInteraction.peerId, false, nil, nil)
            return .invoked
        }
        return .rejected
    }
    
    
    deinit {
        failedMessageEventsDisposable.dispose()
        historyDisposable.dispose()
        peerDisposable.dispose()
        updatedChannelParticipants.dispose()
        readHistoryDisposable.dispose()
        messageActionCallbackDisposable.dispose()
        sentMessageEventsDisposable.dispose()
        chatInteraction.remove(observer: self)
        contextQueryState?.1.dispose()
        self.urlPreviewQueryState?.1.dispose()
        botCallbackAlertMessageDisposable?.dispose()
        layoutDisposable.dispose()
        shareContactDisposable.dispose()
        peerInputActivitiesDisposable.dispose()
        connectionStatusDisposable.dispose()
        messagesActionDisposable.dispose()
        unblockDisposable.dispose()
        updatePinnedDisposable.dispose()
        reportPeerDisposable.dispose()
        focusMessageDisposable.dispose()
        updateFontSizeDisposable.dispose()
        context.addRecentlyUsedPeer(peerId: chatInteraction.peerId)
        loadFwdMessagesDisposable.dispose()
        chatUnreadMentionCountDisposable.dispose()
        navigationActionDisposable.dispose()
        messageIndexDisposable.dispose()
        dateDisposable.dispose()
        interactiveReadingDisposable.dispose()
        showRightControlsDisposable.dispose()
        deleteChatDisposable.dispose()
        loadSelectionMessagesDisposable.dispose()
        updateMediaDisposable.dispose()
        editCurrentMessagePhotoDisposable.dispose()
        selectMessagePollOptionDisposables.dispose()
        onlineMemberCountDisposable.dispose()
        chatUndoDisposable.dispose()
        chatInteraction.clean()
        discussionDataLoadDisposable.dispose()
        _ = previousView.swap(nil)
        
        context.closeFolderFirst = false
    }
    
    
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        genericView.inputContextHelper.viewWillRemove()
        self.chatInteraction.remove(observer: self)
        chatInteraction.saveState(scrollState: immediateScrollState())
        
        context.window.removeAllHandlers(for: self)
        
        if let window = window {
            selectTextController.removeHandlers(for: window)
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
    
    override func didRemovedFromStack() {
        super.didRemovedFromStack()
        editMessageDisposable.dispose()
    }
    
    private var splitStateFirstUpdate: Bool = true
    override func viewDidChangedNavigationLayout(_ state: SplitViewState) -> Void {
        super.viewDidChangedNavigationLayout(state)
        chatInteraction.update(animated: false, {$0.withUpdatedLayout(state).withToggledSidebarEnabled(FastSettings.sidebarEnabled).withToggledSidebarShown(FastSettings.sidebarShown)})
        if !splitStateFirstUpdate {
            Queue.mainQueue().justDispatch { [weak self] in
                self?.genericView.tableView.layoutItems()
            }
        }
        splitStateFirstUpdate = false
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        let context = self.context
        context.closeFolderFirst = false

        
        chatInteraction.update(animated: false, {$0.withToggledSidebarEnabled(FastSettings.sidebarEnabled).withToggledSidebarShown(FastSettings.sidebarShown)})
        //NSLog("chat apeeared")
        
         self.failedMessageEventsDisposable.set((context.account.pendingMessageManager.failedMessageEvents(peerId: chatInteraction.peerId)
         |> deliverOnMainQueue).start(next: { [weak self] reason in
            if let strongSelf = self {
                let text: String
                switch reason {
                case .flood:
                    text = L10n.chatSendMessageErrorFlood
                case .publicBan:
                    text = L10n.chatSendMessageErrorGroupRestricted
                case .mediaRestricted:
                    text = L10n.chatSendMessageErrorGroupRestricted
                    
                }
                confirm(for: mainWindow, information: text, cancelTitle: "", thridTitle: L10n.genericErrorMoreInfo, successHandler: { [weak strongSelf] confirm in
                    guard let strongSelf = strongSelf else {return}
                    
                    switch confirm {
                    case .thrid:
                        execute(inapp: inAppLink.followResolvedName(link: "@spambot", username: "spambot", postId: nil, context: context, action: nil, callback: { [weak strongSelf] peerId, openChat, postid, initialAction in
                            strongSelf?.chatInteraction.openInfo(peerId, openChat, postid, initialAction)
                        }))
                    default:
                        break
                    }
                })
            }
         }))
 
        
        if let peer = chatInteraction.peer {
            if peer.isRestrictedChannel, let reason = peer.restrictionText {
                alert(for: mainWindow, info: reason, completion: { [weak self] in
                    self?.dismiss()
                })
            } else if chatInteraction.presentation.isNotAccessible {
                alert(for: mainWindow, info: peer.isChannel ? L10n.chatChannelUnaccessible : L10n.chatGroupUnaccessible, completion: { [weak self] in
                    self?.dismiss()
                })
            }
        }
        
       
        
        self.context.window.set(handler: {[weak self] () -> KeyHandlerResult in
            if let strongSelf = self, !hasModals() {
                let result:KeyHandlerResult = strongSelf.chatInteraction.presentation.effectiveInput.inputText.isEmpty && strongSelf.chatInteraction.presentation.state == .normal ? .invoked : .rejected
                
                
                if result == .invoked {
                    let setup = strongSelf.findAndSetEditableMessage()
                    if !setup {
                        strongSelf.genericView.tableView.scrollUp()
                    }
                } else {
                    if strongSelf.chatInteraction.presentation.effectiveInput.inputText.isEmpty {
                        strongSelf.genericView.tableView.scrollUp()
                    }
                }
                
                return result
            }
            return .rejected
        }, with: self, for: .UpArrow, priority: .low)
        
        self.context.window.set(handler: {[weak self] () -> KeyHandlerResult in
            if let strongSelf = self, !hasModals() {
                let result:KeyHandlerResult = strongSelf.chatInteraction.presentation.effectiveInput.inputText.isEmpty ? .invoked : .invokeNext
                
                
                if result == .invoked {
                    strongSelf.genericView.tableView.scrollDown()
                }
                
                return result
            }
            return .rejected
        }, with: self, for: .DownArrow, priority: .low)
        
        self.context.window.set(handler: { [weak self] () -> KeyHandlerResult in
            if let `self` = self, !hasModals(), self.chatInteraction.presentation.interfaceState.editState == nil, self.chatInteraction.presentation.interfaceState.inputState.inputText.isEmpty {
                var currentReplyId = self.chatInteraction.presentation.interfaceState.replyMessageId
                self.genericView.tableView.enumerateItems(with: { item in
                    if let item = item as? ChatRowItem, let message = item.message {
                        if canReplyMessage(message, peerId: self.chatInteraction.peerId), currentReplyId == nil || (message.id < currentReplyId!) {
                            currentReplyId = message.id
                            self.genericView.tableView.scroll(to: .center(id: item.stableId, innerId: nil, animated: true, focus: true, inset: 0), inset: NSEdgeInsetsZero, timingFunction: .linear)
                            return false
                        }
                    }
                    return true
                })
                
                let result:KeyHandlerResult = currentReplyId != nil ? .invoked : .rejected
                self.chatInteraction.setupReplyMessage(currentReplyId)
                
                return result
            }
            return .rejected
        }, with: self, for: .UpArrow, priority: .low, modifierFlags: [.command])
        
        self.context.window.set(handler: { [weak self] () -> KeyHandlerResult in
            if let `self` = self, !hasModals(), self.chatInteraction.presentation.interfaceState.editState == nil, self.chatInteraction.presentation.interfaceState.inputState.inputText.isEmpty {
                var currentReplyId = self.chatInteraction.presentation.interfaceState.replyMessageId
                self.genericView.tableView.enumerateItems(reversed: true, with: { item in
                    if let item = item as? ChatRowItem, let message = item.message {
                        if canReplyMessage(message, peerId: self.chatInteraction.peerId), currentReplyId != nil && (message.id > currentReplyId!) {
                            currentReplyId = message.id
                            self.genericView.tableView.scroll(to: .center(id: item.stableId, innerId: nil, animated: true, focus: true, inset: 0), inset: NSEdgeInsetsZero, timingFunction: .linear)
                            return false
                        }
                    }
                    return true
                })
                
                let result:KeyHandlerResult = currentReplyId != nil ? .invoked : .rejected
                self.chatInteraction.setupReplyMessage(currentReplyId)
                
                return result
            }
            return .rejected
        }, with: self, for: .DownArrow, priority: .low, modifierFlags: [.command])
        
        
        self.context.window.set(handler: { [weak self] () -> KeyHandlerResult in
            guard let `self` = self, !hasModals() else {return .rejected}
            
            if let selectionState = self.chatInteraction.presentation.selectionState, !selectionState.selectedIds.isEmpty {
                self.chatInteraction.deleteSelectedMessages()
                return .invoked
            }
            
            return .rejected
        }, with: self, for: .Delete, priority: .low)
        
        self.context.window.set(handler: { [weak self] () -> KeyHandlerResult in
            guard let `self` = self else {return .rejected}
            
            if let selectionState = self.chatInteraction.presentation.selectionState, !selectionState.selectedIds.isEmpty {
                self.chatInteraction.deleteSelectedMessages()
                return .invoked
            }
            
            return .rejected
        }, with: self, for: .ForwardDelete, priority: .low)
        
        

        
        self.context.window.set(handler: { [weak self] () -> KeyHandlerResult in
            if let strongSelf = self, strongSelf.context.window.firstResponder != strongSelf.genericView.inputView.textView.inputView {
                _ = strongSelf.context.window.makeFirstResponder(strongSelf.genericView.inputView)
                return .invoked
            } else if (self?.navigationController as? MajorNavigationController)?.genericView.state == .single {
                return .invoked
            }
            return .rejected
        }, with: self, for: .Tab, priority: .high)
        
      
        
        self.context.window.set(handler: { [weak self] () -> KeyHandlerResult in
            guard let `self` = self else {return .rejected}
            if !self.chatInteraction.presentation.isSearchMode.0 {
                self.chatInteraction.update({$0.updatedSearchMode((true, nil))})
            } else {
                self.genericView.applySearchResponder()
            }

            return .invoked
        }, with: self, for: .F, priority: .medium, modifierFlags: [.command])
        
    
        
//        self.context.window.set(handler: { [weak self] () -> KeyHandlerResult in
//            guard let `self` = self else {return .rejected}
//            if let editState = self.chatInteraction.presentation.interfaceState.editState, let media = editState.originalMedia as? TelegramMediaImage {
//                self.chatInteraction.editEditingMessagePhoto(media)
//            }
//            return .invoked
//        }, with: self, for: .E, priority: .medium, modifierFlags: [.command])
        
      
        self.context.window.set(handler: { [weak self] () -> KeyHandlerResult in
            self?.genericView.inputView.makeBold()
            return .invoked
        }, with: self, for: .B, priority: .medium, modifierFlags: [.command])
        
        self.context.window.set(handler: { [weak self] () -> KeyHandlerResult in
            self?.genericView.inputView.makeUrl()
            return .invoked
        }, with: self, for: .U, priority: .medium, modifierFlags: [.command])
        
        self.context.window.set(handler: { [weak self] () -> KeyHandlerResult in
            self?.genericView.inputView.makeItalic()
            return .invoked
        }, with: self, for: .I, priority: .medium, modifierFlags: [.command])
        
        self.context.window.set(handler: { [weak self] () -> KeyHandlerResult in
            self?.chatInteraction.startRecording(true)
            return .invoked
        }, with: self, for: .R, priority: .medium, modifierFlags: [.command])
        
        
        self.context.window.set(handler: { [weak self] () -> KeyHandlerResult in
            self?.genericView.inputView.makeMonospace()
            return .invoked
        }, with: self, for: .K, priority: .medium, modifierFlags: [.command, .shift])
        
        
        self.context.window.add(swipe: { [weak self] direction -> SwipeHandlerResult in
            guard let `self` = self, let window = self.window, self.chatInteraction.presentation.state == .normal else {return .failed}
            let swipeState: SwipeState?
            switch direction {
            case .left:
               return .failed
            case let .right(_state):
                swipeState = _state
            case .none:
                swipeState = nil
            }
            
            guard let state = swipeState else {return .failed}
            
            switch state {
            case .start:
                let row = self.genericView.tableView.row(at: self.genericView.tableView.clipView.convert(window.mouseLocationOutsideOfEventStream, from: nil))
                if row != -1 {
                   
                    guard let item = self.genericView.tableView.item(at: row) as? ChatRowItem, let message = item.message, canReplyMessage(message, peerId: self.chatInteraction.peerId) else {return .failed}
                    self.removeRevealStateIfNeeded(message.id)
                    (item.view as? RevealTableView)?.initRevealState()
                    return .success(RevealTableItemController(item: item))
                } else {
                    return .failed
                }
                
            case let .swiping(_delta, controller):
                let controller = controller as! RevealTableItemController
                
                guard let view = controller.item.view as? RevealTableView else {return .nothing}
                
                var delta:CGFloat
                switch direction {
                case .left:
                    delta = _delta//max(0, _delta)
                case .right:
                    delta = -_delta//min(-_delta, 0)
                default:
                    delta = _delta
                }
                
                let newDelta = min(min(300, view.width) * log2(abs(delta) + 1) * log2(min(300, view.width)) / 100.0, abs(delta))
                
                if delta < 0 {
                    delta = -newDelta
                } else {
                    delta = newDelta
                }

                
                view.moveReveal(delta: delta)
            case let .success(_, controller), let .failed(_, controller):
                let controller = controller as! RevealTableItemController
                guard let view = (controller.item.view as? RevealTableView) else {return .nothing}
                
                
                view.completeReveal(direction: direction)
            }
            
            //  return .success()
            
            return .nothing
        }, with: self.genericView.tableView, identifier: "chat-reply-swipe")
        
        
        if !(context.window.firstResponder is NSTextView) {
            self.genericView.inputView.makeFirstResponder()
        }

        if let window = window {
            selectTextController.initializeHandlers(for: window, chatInteraction:chatInteraction)
        }
        
        _ = context.window.makeFirstResponder(genericView.inputView.textView.inputView)
        
    }
    
    private func removeRevealStateIfNeeded(_ messageId: MessageId) -> Void {
        
    }
    
    func findAndSetEditableMessage(_ bottom: Bool = false) -> Bool {
        let view = self.previousView.with { $0 }
        if let view = view?.originalView, view.laterId == nil {
            for entry in (!bottom ? view.entries.reversed() : view.entries) {
                if let messageId = chatInteraction.presentation.interfaceState.editState?.message.id {
                    if (messageId <= entry.message.id && !bottom) || (messageId >= entry.message.id && bottom) {
                        continue
                    }
                }
                if canEditMessage(entry.message, context: context)  {
                    chatInteraction.beginEditingMessage(entry.message)
                    return true
                }
            }
        }
        return false
    }
    
    override func firstResponder() -> NSResponder? {
        return self.genericView.responder
    }
    
    override var responderPriority: HandlerPriority {
        return .medium
    }
    
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        context.globalPeerHandler.set(.single(chatLocation))
        self.chatInteraction.add(observer: self)
        
        if let controller = globalAudio {
            (self.navigationController?.header?.view as? InlineAudioPlayerView)?.update(with: controller, context: context, tableView: genericView.tableView)
        }
        
    }
    
    private func updateMaxVisibleReadIncomingMessageIndex(_ index: MessageIndex) {
        self.maxVisibleIncomingMessageIndex.set(index)
    }
    
    
    override func invokeNavigation(action:NavigationModalAction) {
        super.invokeNavigation(action: action)
        chatInteraction.applyAction(action: action)
    }
    
    private let isAdChat: Bool
    private let messageId: MessageId?
    
    public init(context: AccountContext, chatLocation:ChatLocation, messageId:MessageId? = nil, initialAction:ChatInitialAction? = nil) {
        self.chatLocation = chatLocation
        self.messageId = messageId 
        self.chatInteraction = ChatInteraction(chatLocation: chatLocation, context: context)
        if let action = initialAction {
            switch action {
            case .ad:
                isAdChat = true
            default:
                isAdChat = false
            }
        } else {
            isAdChat = false
        }
        super.init(context)
        
        
        //NSLog("init chat controller")
        self.chatInteraction.update(animated: false, {$0.updatedInitialAction(initialAction)})
        context.checkFirstRecentlyForDuplicate(peerId: chatInteraction.peerId)
        
        self.messageProcessingManager.process = { messageIds in
            context.account.viewTracker.updateViewCountForMessageIds(messageIds: messageIds.filter({$0.namespace == Namespaces.Message.Cloud}))
        }

        self.unsupportedMessageProcessingManager.process = { messageIds in
            context.account.viewTracker.updateUnsupportedMediaForMessageIds(messageIds: messageIds.filter({$0.namespace == Namespaces.Message.Cloud}))
        }
        self.messageMentionProcessingManager.process = { messageIds in
            context.account.viewTracker.updateMarkMentionsSeenForMessageIds(messageIds: messageIds.filter({$0.namespace == Namespaces.Message.Cloud}))
        }
        
        
        self.location.set(peerView.get() |> take(1) |> deliverOnMainQueue |> map { [weak self] view -> ChatHistoryLocation in
            
            if let strongSelf = self {
                let count = Int(round(strongSelf.view.frame.height / 28)) + 30
                let location:ChatHistoryLocation
                if let messageId = messageId {
                    location = .InitialSearch(location: .id(messageId), count: count)
                } else {
                    location = .Initial(count: count)
                }
                
                return location
            }
            return .Initial(count: 30)
        })
        _ = (self.location.get() |> take(1) |> deliverOnMainQueue).start(next: { [weak self] location in
            _ = self?._locationValue.swap(location)
        })
    }
    
    func notify(with value: Any, oldValue: Any, animated:Bool) {
        notify(with: value, oldValue: oldValue, animated: animated, force: false)
    }
    
    private var isPausedGlobalPlayer: Bool = false
    
    func notify(with value: Any, oldValue: Any, animated:Bool, force:Bool) {
        if let value = value as? ChatPresentationInterfaceState, let oldValue = oldValue as? ChatPresentationInterfaceState {
            
            let context = self.context
            
            
            if value.selectionState != oldValue.selectionState {
                if let selectionState = value.selectionState {
                    let ids = Array(selectionState.selectedIds)
                    loadSelectionMessagesDisposable.set((context.account.postbox.messagesAtIds(ids) |> deliverOnMainQueue).start( next:{ [weak self] messages in
                        var canDelete:Bool = !ids.isEmpty
                        var canForward:Bool = !ids.isEmpty
                        for message in messages {
                            if !canDeleteMessage(message, account: context.account) {
                                canDelete = false
                            }
                            if !canForwardMessage(message, account: context.account) {
                                canForward = false
                            }
                        }
                        self?.chatInteraction.update({$0.withUpdatedBasicActions((canDelete, canForward))})
                    }))
                } else {
                    chatInteraction.update({$0.withUpdatedBasicActions((false, false))})
                }
            }
            
//            if #available(OSX 10.12.2, *) {
//                self.context.window.touchBar = self.context.window.makeTouchBar()
//            }
            
            if oldValue.recordingState == nil && value.recordingState != nil {
                if let pause = globalAudio?.pause() {
                    isPausedGlobalPlayer = pause
                }
            } else if value.recordingState == nil && oldValue.recordingState != nil {
                if isPausedGlobalPlayer {
                    _ = globalAudio?.play()
                }
            }
            
            if value.inputQueryResult != oldValue.inputQueryResult {
                genericView.inputContextHelper.context(with: value.inputQueryResult, for: genericView, relativeView: genericView.inputView, animated: animated)
            }
            if value.interfaceState.inputState != oldValue.interfaceState.inputState {
                chatInteraction.saveState(false, scrollState: immediateScrollState())
                
            }
            
            if value.selectionState != oldValue.selectionState {
                doneButton?.isHidden = value.selectionState == nil
                editButton?.isHidden = value.selectionState != nil
            }
            
            if value.effectiveInput != oldValue.effectiveInput || force {
                if let (updatedContextQueryState, updatedContextQuerySignal) = contextQueryResultStateForChatInterfacePresentationState(chatInteraction.presentation, context: self.context, currentQuery: self.contextQueryState?.0) {
                    self.contextQueryState?.1.dispose()
                    var inScope = true
                    var inScopeResult: ((ChatPresentationInputQueryResult?) -> ChatPresentationInputQueryResult?)?
                    self.contextQueryState = (updatedContextQueryState, (updatedContextQuerySignal |> deliverOnMainQueue).start(next: { [weak self] result in
                        if let strongSelf = self {
                            if Thread.isMainThread && inScope {
                                inScope = false
                                inScopeResult = result
                            } else {
                                strongSelf.chatInteraction.update(animated: animated, {
                                    $0.updatedInputQueryResult { previousResult in
                                        return result(previousResult)
                                    }
                                })
                                
                            }
                        }
                    }))
                    inScope = false
                    if let inScopeResult = inScopeResult {
                        
                        chatInteraction.update(animated: animated, {
                            $0.updatedInputQueryResult { previousResult in
                                return inScopeResult(previousResult)
                            }
                        })
                        
                    }
                    

                    if let (updatedUrlPreviewUrl, updatedUrlPreviewSignal) = urlPreviewStateForChatInterfacePresentationState(chatInteraction.presentation, account: context.account, currentQuery: self.urlPreviewQueryState?.0) {
                        self.urlPreviewQueryState?.1.dispose()
                        var inScope = true
                        var inScopeResult: ((TelegramMediaWebpage?) -> TelegramMediaWebpage?)?
                        self.urlPreviewQueryState = (updatedUrlPreviewUrl, (updatedUrlPreviewSignal |> deliverOnMainQueue).start(next: { [weak self] result in
                            if let strongSelf = self {
                                if Thread.isMainThread && inScope {
                                    inScope = false
                                    inScopeResult = result
                                } else {
                                    strongSelf.chatInteraction.update(animated: true, {
                                        if let updatedUrlPreviewUrl = updatedUrlPreviewUrl, let webpage = result($0.urlPreview?.1) {
                                            return $0.updatedUrlPreview((updatedUrlPreviewUrl, webpage))
                                        } else {
                                            return $0.updatedUrlPreview(nil)
                                        }
                                    })
                                }
                            }
                        }))
                        inScope = false
                        if let inScopeResult = inScopeResult {
                            chatInteraction.update(animated: true, {
                                if let updatedUrlPreviewUrl = updatedUrlPreviewUrl, let webpage = inScopeResult($0.urlPreview?.1) {
                                    return $0.updatedUrlPreview((updatedUrlPreviewUrl, webpage))
                                } else {
                                    return $0.updatedUrlPreview(nil)
                                }
                            })
                        }
                    }
                }
            }
            
            if value.isSearchMode.0 != oldValue.isSearchMode.0 || value.pinnedMessageId != oldValue.pinnedMessageId || value.reportStatus != oldValue.reportStatus || value.interfaceState.dismissedPinnedMessageId != oldValue.interfaceState.dismissedPinnedMessageId || value.canAddContact != oldValue.canAddContact || value.initialAction != oldValue.initialAction || value.restrictionInfo != oldValue.restrictionInfo {
                genericView.updateHeader(value, animated)
            }
            
            if value.peer != nil && oldValue.peer == nil {
                genericView.tableView.emptyItem = ChatEmptyPeerItem(genericView.tableView.frame.size, chatInteraction: chatInteraction)
            }
            
            self.state = value.selectionState != nil ? .Edit : .Normal
            
            
           
        }
    }
    
    
    func immediateScrollState() -> ChatInterfaceHistoryScrollState? {
        
        var message:Message?
        var index:Int?
        self.genericView.tableView.enumerateVisibleItems(reversed: true, with: { item -> Bool in
            
            if let item = item as? ChatRowItem {
                message = item.message
                index = item.index
            }
            return message == nil
        })
        
        if let visibleIndex = index, let message = message {
            let rect = genericView.tableView.rectOf(index: visibleIndex)
            let top = genericView.tableView.documentOffset.y + genericView.tableView.frame.height
            if genericView.tableView.frame.height >= genericView.tableView.documentOffset.y && historyState.isDownOfHistory {
                return nil
            } else {
                let relativeOffset: CGFloat = top - rect.maxY
                return ChatInterfaceHistoryScrollState(messageIndex: MessageIndex(message), relativeOffset: Double(relativeOffset))
            }
        }
        
        return nil
    }
  

    func isEqual(to other: Notifable) -> Bool {
        if let other = other as? ChatController {
            return other == self
        }
        return false
    }
    
    override var rightSwipeController: ViewController? {
        return nil//chatInteraction.peerId == account.peerId ? PeerMediaController(account: account, peerId: chatInteraction.peerId, tagMask: .photoOrVideo) : PeerInfoController(account: account, peerId: chatInteraction.peerId)
    }
    
    
    public override func draggingExited() {
        super.draggingExited()
        genericView.inputView.isHidden = false
    }
    public override func draggingEntered() {
        super.draggingEntered()
        genericView.inputView.isHidden = true
    }
    
    public override func draggingItems(for pasteboard:NSPasteboard) -> [DragItem] {
        
        if hasModals() {
            return []
        }
        
        if let types = pasteboard.types, types.contains(.kFilenames) {
            let list = pasteboard.propertyList(forType: .kFilenames) as? [String]
            
            if let list = list, list.count > 0, let peer = chatInteraction.peer, peer.canSendMessage {
                
                if let text = permissionText(from: peer, for: .banSendMedia) {
                    return [DragItem(title: "", desc: text, handler: {
                        
                    })]
                }
                
                var items:[DragItem] = []
                
                let list = list.filter { path -> Bool in
                    if let size = fs(path) {
                        return size <= 1500 * 1024 * 1024
                    }

                    return false
                }
                
                if !list.isEmpty {
                    let asMediaItem = DragItem(title:tr(L10n.chatDropTitle), desc: tr(L10n.chatDropQuickDesc), handler:{ [weak self] in
                        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                        if shift {
                            self?.chatInteraction.sendMedia(list.map{MediaSenderContainer(path: $0, caption: "", isFile: false)})
                        } else {
                            self?.chatInteraction.showPreviewSender(list.map { URL(fileURLWithPath: $0) }, true)
                        }
                    })
                    let fileTitle: String
                    let fileDesc: String
                    
                    if list.count == 1, list[0].isDirectory {
                        fileTitle = L10n.chatDropFolderTitle
                        fileDesc = L10n.chatDropFolderDesc
                    } else {
                        fileTitle = L10n.chatDropTitle
                        fileDesc = L10n.chatDropAsFilesDesc
                    }
                    let asFileItem = DragItem(title: fileTitle, desc: fileDesc, handler: { [weak self] in
                        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                        if shift {
                            self?.chatInteraction.sendMedia(list.map{MediaSenderContainer(path: $0, caption: "", isFile: true)})
                        } else {
                            self?.chatInteraction.showPreviewSender(list.map { URL(fileURLWithPath: $0) }, false)
                        }
                    })
                    
                    items.append(asFileItem)
                    
                    
                    var asMedia:Bool = false
                    for path in list {
                        if mediaExts.contains(path.nsstring.pathExtension.lowercased()) {
                            asMedia = true
                            break
                        }
                    }
                    
                    if asMedia {
                        items.append(asMediaItem)
                    } 
    
                }

                return items
            }
            //NSTIFFPboardType
        } else if let types = pasteboard.types, types.contains(.tiff) {
            let data = pasteboard.data(forType: .tiff)
            if let data = data, let image = NSImage(data: data) {
                
                var items:[DragItem] = []

                let asMediaItem = DragItem(title:tr(L10n.chatDropTitle), desc: tr(L10n.chatDropQuickDesc), handler:{ [weak self] in
                    _ = (putToTemp(image: image) |> deliverOnMainQueue).start(next: { [weak self] path in
                        self?.chatInteraction.showPreviewSender([URL(fileURLWithPath: path)], true)
                    })

                })
                
                let asFileItem = DragItem(title:tr(L10n.chatDropTitle), desc: tr(L10n.chatDropAsFilesDesc), handler:{ [weak self] in
                    _ = (putToTemp(image: image) |> deliverOnMainQueue).start(next: { [weak self] path in
                        self?.chatInteraction.showPreviewSender([URL(fileURLWithPath: path)], false)
                    })
                })
                
                items.append(asFileItem)
                items.append(asMediaItem)
                
                return items
            }
        }
        
        return []
    }
    
    override public var isOpaque: Bool {
        return false
    }

    override open func backSettings() -> (String,CGImage?) {
        if context.sharedContext.layout == .single {
            return super.backSettings()
        }
        return (tr(L10n.navigationClose),nil)
    }

    override public func update(with state:ViewControllerState) -> Void {
        super.update(with:state)
        chatInteraction.update({state == .Normal ? $0.withoutSelectionState() : $0.withSelectionState()})
        context.window.applyResponderIfNeeded()
    }
    
    override func initializer() -> ChatControllerView {
        return ChatControllerView(frame: NSMakeRect(_frameRect.minX, _frameRect.minY, _frameRect.width, _frameRect.height - self.bar.height), chatInteraction:chatInteraction);
    }
    
    override func requestUpdateCenterBar() {
       
    }
    
    override func updateLocalizationAndTheme() {
        super.updateLocalizationAndTheme()
        updateBackgroundColor(theme.backgroundMode)
        (centerBarView as? ChatTitleBarView)?.updateStatus()
    }
    
    
    func selectionDidChange(row:Int, item:TableRowItem, byClick:Bool, isNew:Bool) -> Void {
        
    }
    func selectionWillChange(row:Int, item:TableRowItem, byClick: Bool) -> Bool {
        return false
    }
    func isSelectable(row:Int, item:TableRowItem) -> Bool {
        return false
    }
    func findGroupStableId(for stableId: AnyHashable) -> AnyHashable? {
        if let view = previousView.with({$0}), let stableId = stableId.base as? ChatHistoryEntryId {
            switch stableId {
            case let .message(message):
                for entry in view.filteredEntries {
                    s: switch entry.entry {
                    case let .groupedPhotos(entries, _):
                        for groupedEntry in entries {
                            if message.id == groupedEntry.message?.id {
                                return entry.stableId
                            }
                        }
                    default:
                        break s
                    }
                }
            default:
                break
            }
        }
        return nil
    }

    
}
