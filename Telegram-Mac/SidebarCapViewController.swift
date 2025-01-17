//
//  SidebarCapViewController.swift
//  Telegram
//
//  Created by keepcoder on 28/04/2017.
//  Copyright © 2017 Telegram. All rights reserved.
//

import Cocoa
import TGUIKit
import PostboxMac
import TelegramCoreMac
import SwiftSignalKitMac

class SidebarCapView : View {
    private let text:NSTextField = NSTextField()
    fileprivate let close:TitleButton = TitleButton()
    fileprivate var restrictedByPeer: Bool = false
    required init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        
        text.font = .normal(.header)
        text.drawsBackground = false
       // text.backgroundColor = .clear
        text.isSelectable = false
        text.isEditable = false
        text.isBordered = false
        text.focusRingType = .none
        text.isBezeled = false
        
        
        addSubview(text)
        
        close.set(font: .medium(.title), for: .Normal)
       
        
        addSubview(close)
        updateLocalizationAndTheme()
    }
    
    override func updateLocalizationAndTheme() {
        super.updateLocalizationAndTheme()
        text.textColor = theme.colors.grayText
        text.stringValue = restrictedByPeer ? L10n.sidebarPeerRestricted : L10n.sidebarAvalability
        text.setFrameSize(text.sizeThatFits(NSMakeSize(300, 100)))
        self.background = theme.colors.background.withAlphaComponent(0.97)
        close.set(color: theme.colors.blueUI, for: .Normal)
        close.set(text: tr(L10n.navigationClose), for: .Normal)
        _ = close.sizeToFit()
        needsLayout = true
    }
    
    
    override func scrollWheel(with event: NSEvent) {
        
    }
    
    override var isFlipped: Bool {
        return true
    }
    
    override func layout() {
        super.layout()
        text.center()
        close.centerX(y: text.frame.maxY + 10)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class SidebarCapViewController: GenericViewController<SidebarCapView> {
    private let context:AccountContext
    private let globalPeerDisposable = MetaDisposable()
    private var inChatAbility: Bool = true {
        didSet {
            navigationWillChangeController()
        }
    }
    init(_ context:AccountContext) {
        self.context = context
        super.init()
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.navigationController = context.sharedContext.bindings.rootNavigation()
        (navigationController as? MajorNavigationController)?.add(listener: WeakReference(value: self))
        genericView.close.set(handler: { [weak self] _ in
            self?.context.sharedContext.bindings.rootNavigation().closeSidebar()
            FastSettings.toggleSidebarShown(false)
            self?.context.sharedContext.bindings.entertainment().closedBySide()
        }, for: .Click)
        
        let postbox = self.context.account.postbox
        
        globalPeerDisposable.set((context.globalPeerHandler.get() |> mapToSignal { value -> Signal<Bool, NoError> in
            if let value = value {
                switch value {
                case let .peer(peerId):
                    return postbox.transaction { transaction -> Bool in
                        return transaction.getPeer(peerId)?.canSendMessage ?? false
                    }
                }
            } else {
                return .single(false)
            }
        } |> deliverOnMainQueue).start(next: { [weak self] accept in
            self?.readyOnce()
            self?.inChatAbility = accept
        }))
    }
    
    deinit {
        
    }
    

    override func navigationWillChangeController() {
        
        self.genericView.restrictedByPeer = !inChatAbility
        self.genericView.updateLocalizationAndTheme()
        
        self.view.setFrameSize(context.sharedContext.bindings.entertainment().frame.size)
        
        if context.sharedContext.bindings.rootNavigation().controller is ChatController, inChatAbility {
            view.removeFromSuperview()
        } else {
            context.sharedContext.bindings.entertainment().addSubview(view)
        }
        
       // NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: mainWindow)

    }
    
}
