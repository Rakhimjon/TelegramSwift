//
//  GroupBlackListViewController.swift
//  Telegram
//
//  Created by keepcoder on 22/02/2017.
//  Copyright © 2017 Telegram. All rights reserved.
//

import Cocoa
import TGUIKit
import PostboxMac
import TelegramCoreMac
import SwiftSignalKitMac


private final class ChannelBlacklistControllerArguments {
    let context: AccountContext
    
    let removePeer: (PeerId) -> Void
    let openInfo:(PeerId) -> Void
    let addMember:()->Void
    let returnToGroup:(PeerId) -> Void
    init(context: AccountContext, removePeer: @escaping (PeerId) -> Void, openInfo:@escaping(PeerId) -> Void, addMember:@escaping()->Void, returnToGroup: @escaping(PeerId) -> Void) {
        self.context = context
        self.removePeer = removePeer
        self.openInfo = openInfo
        self.addMember = addMember
        self.returnToGroup = returnToGroup
    }
}

private enum ChannelBlacklistEntryStableId: Hashable {
    case peer(PeerId)
    case empty
    case addMember
    case section(Int32)
    case header(Int32)
    var hashValue: Int {
        switch self {
        case let .peer(peerId):
            return peerId.hashValue
        case .empty:
            return 0
        case .section:
            return 1
        case .header:
            return 2
        case .addMember:
            return 3
        }
    }
    
}

private enum ChannelBlacklistEntry: Identifiable, Comparable {
    case peerItem(Int32, Int32, RenderedChannelParticipant, ShortPeerDeleting?, Bool, Bool)
    case empty(Bool)
    case header(Int32, Int32, String)
    case section(Int32)
    case addMember(Int32, Int32)
    var stableId: ChannelBlacklistEntryStableId {
        switch self {
        case let .peerItem(_, _, participant, _, _, _):
            return .peer(participant.peer.id)
        case .empty:
            return .empty
        case .section(let section):
            return .section(section)
        case .header(_, let index, _):
            return .header(index)
        case .addMember:
            return .addMember
        }
    }
    

    
    var index:Int32 {
        switch self {
        case let .section(section):
            return (section * 1000) - section
        case let .header(section, index, _):
            return (section * 1000) + index
        case let .addMember(section, index):
            return (section * 1000) + index
        case .empty:
            return 0
        case let .peerItem(section, index, _, _, _, _):
            return (section * 1000) + index

        }
    }
    
    static func <(lhs: ChannelBlacklistEntry, rhs: ChannelBlacklistEntry) -> Bool {
        return lhs.index < rhs.index
    }
    
    func item(_ arguments: ChannelBlacklistControllerArguments, initialSize:NSSize) -> TableRowItem {
        switch self {
        case let .peerItem(_, _, participant, editing, enabled, isChannel):
            
            let interactionType:ShortPeerItemInteractionType
            if let editing = editing {
                
                interactionType = .deletable(onRemove: { peerId in
                    arguments.removePeer(peerId)
                }, deletable: editing.editable)
            } else {
                interactionType = .plain
            }
            
            var string:String = L10n.peerStatusRecently
            
            if case let .member(_, _, _, banInfo) = participant.participant {
                if let banInfo = banInfo, let peer = participant.peers[banInfo.restrictedBy] {
                    if banInfo.rights.flags.contains(.banReadMessages) {
                        string = L10n.channelBlacklistBlockedBy(peer.displayTitle)
                    } else {
                        string = L10n.channelBlacklistRestrictedBy(peer.displayTitle)
                    }
                } else {
                    if let peer = participant.peer as? TelegramUser, let botInfo = peer.botInfo {
                        string = botInfo.flags.contains(.hasAccessToChatHistory) ? L10n.peerInfoBotStatusHasAccess : L10n.peerInfoBotStatusHasNoAccess
                    } else if let presence = participant.presences[participant.peer.id] as? TelegramUserPresence {
                        let timestamp = CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970
                        (string,_, _) = stringAndActivityForUserPresence(presence, timeDifference: arguments.context.timeDifference, relativeTo: Int32(timestamp))
                    }
                }
            }

            return ShortPeerRowItem(initialSize, peer: participant.peer, account: arguments.context.account, stableId: stableId, enabled: enabled, height:44, photoSize: NSMakeSize(32, 32), status: string, drawLastSeparator: true, inset: NSEdgeInsets(left: 30, right: 30), interactionType: interactionType, generalType: .none, action: {
                if case .plain = interactionType {
                    arguments.openInfo(participant.peer.id)
                }
            }, contextMenuItems: {
                var items:[ContextMenuItem] = []
                items.append(ContextMenuItem(L10n.channelBlacklistContextRemove, handler: {
                    arguments.removePeer(participant.peer.id)
                }))
                if !isChannel {
                    items.append(ContextMenuItem(L10n.channelBlacklistContextAddToGroup, handler: {
                        arguments.returnToGroup(participant.peer.id)
                    }))
                }
                
                return items
            })
        case let .empty(progress):
            return SearchEmptyRowItem(initialSize, stableId: stableId, isLoading: progress, text: L10n.channelBlacklistEmptyDescrpition)
        case .section:
            return GeneralRowItem(initialSize, height: 20, stableId: stableId)
        case .header(_, _, let text):
            return GeneralTextRowItem(initialSize, stableId: stableId, text: text, drawCustomSeparator: false, inset: NSEdgeInsets(left: 30.0, right: 30.0, top:2, bottom:6))
        case .addMember:
            return GeneralInteractedRowItem(initialSize, stableId: stableId, name: L10n.channelBlacklistRemoveUser, nameStyle: blueActionButton, action: {
                arguments.addMember()
            })
        }
    }
}

private struct ChannelBlacklistControllerState: Equatable {
    let editing: Bool
    let removingPeerId: PeerId?
    
    init() {
        self.editing = false
        self.removingPeerId = nil
    }
    
    init(editing: Bool, removingPeerId: PeerId?) {
        self.editing = editing
        self.removingPeerId = removingPeerId
    }
    

    func withUpdatedEditing(_ editing: Bool) -> ChannelBlacklistControllerState {
        return ChannelBlacklistControllerState(editing: editing, removingPeerId: self.removingPeerId)
    }
    
    func withUpdatedPeerIdWithRevealedOptions(_ peerIdWithRevealedOptions: PeerId?) -> ChannelBlacklistControllerState {
        return ChannelBlacklistControllerState(editing: self.editing, removingPeerId: self.removingPeerId)
    }
    
    func withUpdatedRemovingPeerId(_ removingPeerId: PeerId?) -> ChannelBlacklistControllerState {
        return ChannelBlacklistControllerState(editing: self.editing, removingPeerId: removingPeerId)
    }
}

private func channelBlacklistControllerEntries(view: PeerView, state: ChannelBlacklistControllerState, participants: [RenderedChannelParticipant]?) -> [ChannelBlacklistEntry] {
    
    var entries: [ChannelBlacklistEntry] = []
    
    var index:Int32 = 0
    var sectionId:Int32 = 1
    
    
    
    if let peer = peerViewMainPeer(view) as? TelegramChannel {
        if peer.hasPermission(.banMembers) {
            
            entries.append(.section(sectionId))
            sectionId += 1
            
            entries.append(.addMember(sectionId, index))
            index += 1
            
            if peer.isGroup {
                 entries.append(.header(sectionId, index, L10n.channelBlacklistDescGroup))
            } else {
                entries.append(.header(sectionId, index, L10n.channelBlacklistDescChannel))
            }
            index += 1
        }
    
        if let participants = participants {
            if !participants.isEmpty {
                entries.append(.section(sectionId))
                sectionId += 1
            }
            
            if !participants.isEmpty {
                
                entries.append(.header(sectionId, index, L10n.channelBlacklistBlocked))
                index += 1
                for participant in participants.sorted(by: <) {
                    
                    var editable = true
                    if case .creator = participant.participant {
                        editable = false
                    }
                    
                    var deleting:ShortPeerDeleting? = nil
                    if state.editing {
                        deleting = ShortPeerDeleting(editable: editable)
                    }
                    
                    entries.append(.peerItem(sectionId, index, participant, deleting, state.removingPeerId != participant.peer.id, peer.isChannel))
                    index += 1
                }
            }
        }
    }
    if entries.isEmpty {
        entries.append(.empty(participants == nil))
    }
    
    return entries
}

fileprivate func prepareTransition(left:[AppearanceWrapperEntry<ChannelBlacklistEntry>], right: [AppearanceWrapperEntry<ChannelBlacklistEntry>], initialSize:NSSize, arguments:ChannelBlacklistControllerArguments) -> TableUpdateTransition {
    
    let (removed, inserted, updated) = proccessEntriesWithoutReverse(left, right: right) { entry -> TableRowItem in
        return entry.entry.item(arguments, initialSize: initialSize)
    }
    
    return TableUpdateTransition(deleted: removed, inserted: inserted, updated: updated, animated: true)
}


class ChannelBlacklistViewController: EditableViewController<TableView> {

    private let peerId:PeerId
    
    private let statePromise = ValuePromise(ChannelBlacklistControllerState(), ignoreRepeated: true)
    private let stateValue = Atomic(value: ChannelBlacklistControllerState())
    private let removePeerDisposable:MetaDisposable = MetaDisposable()
    private let updatePeerDisposable = MetaDisposable()
    private let disposable:MetaDisposable = MetaDisposable()
    
    init(_ context:AccountContext, peerId:PeerId) {
        self.peerId = peerId
        super.init(context)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        let context = self.context
        let peerId = self.peerId
        
        let actionsDisposable = DisposableSet()
        
        let updateState: ((ChannelBlacklistControllerState) -> ChannelBlacklistControllerState) -> Void = { [weak self] f in
            if let strongSelf = self {
                strongSelf.statePromise.set(strongSelf.stateValue.modify { f($0) })
            }
        }
        
        let blacklistPromise = Promise<[RenderedChannelParticipant]?>(nil)
        let viewValue:Atomic<PeerView?> = Atomic(value: nil)
        
        let restrict:(PeerId, Bool) -> Void = { [weak self] memberId, unban in
            let signal = context.peerChannelMemberCategoriesContextsManager.updateMemberBannedRights(account: context.account, peerId: peerId, memberId: memberId, bannedRights: unban ? nil : TelegramChatBannedRights(flags: [.banReadMessages], untilDate: Int32.max)) |> ignoreValues
            
            self?.updatePeerDisposable.set(showModalProgress(signal: signal, for: mainWindow).start(error: { _ in
                updateState {
                    return $0.withUpdatedRemovingPeerId(nil)
                }
            }, completed: {
                updateState {
                    return $0.withUpdatedRemovingPeerId(nil)
                }
            }))
        }
        
        let arguments = ChannelBlacklistControllerArguments(context: context, removePeer: { memberId in
            
            updateState {
                return $0.withUpdatedRemovingPeerId(memberId)
            }
            
           restrict(memberId, true)
        }, openInfo: { [weak self] peerId in
            self?.navigationController?.push(PeerInfoController(context: context, peerId: peerId))
        }, addMember: {
            let behavior = SelectChannelMembersBehavior(peerId: peerId, limit: 1)
            
            _ = (selectModalPeers(context: context, title: L10n.channelBlacklistSelectNewUserTitle, limit: 1, behavior: behavior, confirmation: { peerIds in
                if let peerId = peerIds.first {
                    var adminError:Bool = false
                    if let participant = behavior.participants[peerId] {
                        if case let .member(_, _, adminInfo, _) = participant.participant {
                            if let adminInfo = adminInfo {
                                if !adminInfo.canBeEditedByAccountPeer && adminInfo.promotedBy != context.account.peerId {
                                    adminError = true
                                }
                            }
                        } else {
                            adminError = true
                        }
                    }
                    if adminError {
                        alert(for: mainWindow, info: L10n.channelBlacklistDemoteAdminError)
                        return .single(false)
                    }
                }
                return .single(true)
            }) |> map {$0.first} |> filter {$0 != nil} |> map {$0!}).start(next: { memberId in
                restrict(memberId, false)
            })
        }, returnToGroup: { [weak self] memberId in
            updateState {
                return $0.withUpdatedRemovingPeerId(memberId)
            }
            
            let signal = context.peerChannelMemberCategoriesContextsManager.addMember(account: context.account, peerId: peerId, memberId: memberId) |> ignoreValues
            
            self?.updatePeerDisposable.set(showModalProgress(signal: signal, for: mainWindow).start(error: { _ in
                updateState {
                    return $0.withUpdatedRemovingPeerId(nil)
                }
            }, completed: {
                updateState {
                    return $0.withUpdatedRemovingPeerId(nil)
                }
            }))
        })
        
        let peerView = context.account.viewTracker.peerView(peerId)
        
        
        let (listDisposable, loadMoreControl) = context.peerChannelMemberCategoriesContextsManager.banned(postbox: context.account.postbox, network: context.account.network, accountPeerId: context.account.peerId, peerId: peerId, updated: { listState in
            if case .loading(true) = listState.loadingState, listState.list.isEmpty {
                blacklistPromise.set(.single(nil))
            } else {
                blacklistPromise.set(.single(listState.list))
            }
        })
        actionsDisposable.add(listDisposable)

        let initialSize = atomicSize
        let previousEntries:Atomic<[AppearanceWrapperEntry<ChannelBlacklistEntry>]> = Atomic(value: [])

        
        let signal = combineLatest(statePromise.get(), peerView, blacklistPromise.get(), appearanceSignal)
            |> deliverOnMainQueue
            |> map { state, view, blacklist, appearance -> (TableUpdateTransition, PeerView) in
                _ = viewValue.swap(view)
                let entries = channelBlacklistControllerEntries(view: view, state: state, participants: blacklist).map {AppearanceWrapperEntry(entry: $0, appearance: appearance)}
                return (prepareTransition(left: previousEntries.swap(entries), right: entries, initialSize: initialSize.modify{$0}, arguments: arguments), view)
        } |> afterDisposed {
            actionsDisposable.dispose()
        }
        
        disposable.set((signal |> deliverOnMainQueue).start(next: { [weak self] transition, peerView in
            if let strongSelf = self {
                strongSelf.genericView.merge(with: transition)
                strongSelf.readyOnce()
                strongSelf.rightBarView.isHidden = strongSelf.genericView.item(at: 0) is SearchEmptyRowItem
                if let peer = peerViewMainPeer(peerView) as? TelegramChannel {
                    strongSelf.rightBarView.isHidden = strongSelf.rightBarView.isHidden || !peer.hasPermission(.banMembers)
                }
            }
        }))
        
        genericView.setScrollHandler { position in
            if let loadMoreControl = loadMoreControl {
                switch position.direction {
                case .bottom:
                    context.peerChannelMemberCategoriesContextsManager.loadMore(peerId: peerId, control: loadMoreControl)
                default:
                    break
                }
            }
        }
    }
    
    deinit {
        disposable.dispose()
        removePeerDisposable.dispose()
        updatePeerDisposable.dispose()
    }
    
    override func update(with state: ViewControllerState) {
        super.update(with: state)
        self.statePromise.set(stateValue.modify({$0.withUpdatedEditing(state == .Edit)}))
    }
    
}


