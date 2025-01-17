//
//  TelegramTableViewController.swift
//  Telegram
//
//  Created by keepcoder on 26/05/2017.
//  Copyright © 2017 Telegram. All rights reserved.
//

import Cocoa
import TelegramCoreMac
import PostboxMac
import SwiftSignalKitMac
import TGUIKit

class TelegramGenericViewController<T>: GenericViewController<T> where T:NSView {

    let context:AccountContext
    let queue: Queue = Queue(name: "Controller Interface Queue", qos: DispatchQoS.default)
    private let languageDisposable:MetaDisposable = MetaDisposable()
    init(_ context:AccountContext) {
        self.context = context
        super.init()
    }
    

    override func viewDidLoad() {
        super.viewDidLoad()
        languageDisposable.set(appearanceSignal.start(next: { [weak self] _ in
            self?.updateLocalizationAndTheme()
        }))
    }
    
    override func updateLocalizationAndTheme() {
        super.updateLocalizationAndTheme()
        
        self.genericView.background = theme.colors.background
        requestUpdateBackBar()
        requestUpdateCenterBar()
        requestUpdateRightBar()
    }
    
    deinit {
        languageDisposable.dispose()
    }
}

class TelegramViewController: TelegramGenericViewController<NSView> {
    
}




class TableViewController: TelegramGenericViewController<TableView>, TableViewDelegate {
    
   
    
    override func loadView() {
        super.loadView()
        genericView.delegate = self
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
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
        return nil
    }
    
    override var enableBack: Bool {
        return true
    }
    
}


public enum ViewControllerState : Equatable {
    case Edit
    case Normal
    case Some
}


class EditableViewController<T>: TelegramGenericViewController<T> where T: NSView {
    
    
    var editBar:TextButtonBarView!
    
    public var state:ViewControllerState = .Normal {
        didSet {
            if state != oldValue {
                updateEditStateTitles()
            }
        }
    }
    
    override func getRightBarViewOnce() -> BarView {
        return editBar
    }
    
    override var enableBack: Bool {
        return true
    }
    
    func changeState() ->Void {
        
        if case .Normal = state {
            self.state = .Edit
        } else {
            self.state = .Normal
        }
        
        update(with:state)
    }
    
    var doneString:String {
        return localizedString("Navigation.Done")
    }
    var normalString:String {
        return localizedString("Navigation.Edit")
    }
    var someString:String {
        return localizedString("Navigation.Some")
    }
    
    var doneImage:CGImage? {
        return nil
    }
    var normalImage:CGImage? {
        return nil
    }
    var someImage:CGImage? {
        return nil
    }
    
    func updateEditStateTitles() -> Void {
        switch state {
        case .Edit:
            editBar.set(text: doneString, for: .Normal)
        case .Normal:
            editBar.set(text: normalString, for: .Normal)
        case .Some:
            editBar.set(text: someString, for: .Normal)
        }
        editBar.set(color: presentation.colors.blueUI, for: .Normal)
        self.editBar.needsLayout = true
    }
    
    override func requestUpdateRightBar() {
        super.requestUpdateRightBar()
        updateEditStateTitles()
    }
    
    func addHandler() -> Void {
        editBar.set (handler:{[weak self] _ in
            if let strongSelf = self {
                strongSelf.changeState()
            }
        }, for:.Click)
    }
    
    override init(_ context:AccountContext) {
        super.init(context)
        editBar = TextButtonBarView(controller: self, text: "", style: navigationButtonStyle, alignment:.Right)
        addHandler()
    }

    func update(with state:ViewControllerState) -> Void {
        updateEditStateTitles()
    }
    
    public func set(editable: Bool) ->Void {
        editBar.isHidden = !editable
    }
    
    public func set(enabled: Bool) ->Void {
        editBar.isEnabled = enabled
    }
    
    override func updateNavigation(_ navigation: NavigationViewController?) {
        super.updateNavigation(navigation)
        if navigation != nil {
            rightBarView = editBar
            updateEditStateTitles()
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
}

final class Appearance : Equatable {
    let language: TelegramLocalization
    var presentation: TelegramPresentationTheme
    init(language: TelegramLocalization, presentation: TelegramPresentationTheme) {
        self.language = language
        self.presentation = presentation
    }
    
    var newAllocation: Appearance {
        return Appearance(language: language, presentation: presentation)
    }
}

func ==(lhs:Appearance, rhs:Appearance) -> Bool {
    return lhs === rhs //lhs.language === rhs.language && lhs.presentation === rhs.presentation
}

var theme: TelegramPresentationTheme {
    if let presentation = presentation as? TelegramPresentationTheme {
        return presentation
    }
    setDefaultTheme()
    return presentation as! TelegramPresentationTheme
}

var appAppearance:Appearance {
    return Appearance(language: appCurrentLanguage, presentation: theme)
}

var appearanceSignal:Signal<Appearance, NoError> {
    
    var timestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
    
    let dateSignal:Signal<Bool, NoError> = Signal { subscriber in
        
        let nowTimestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)

        
        var now: time_t = time_t(nowTimestamp)
        var timeinfoNow: tm = tm()
        localtime_r(&now, &timeinfoNow)
        
        
        var t: time_t = time_t(timestamp)
        var timeinfo: tm = tm()
        localtime_r(&t, &timeinfo)
        
      
        if timeinfo.tm_year != timeinfoNow.tm_year || timeinfo.tm_yday != timeinfoNow.tm_yday {
            timestamp = nowTimestamp
            subscriber.putNext(true)
        } else {
            subscriber.putNext(false)
        }
        subscriber.putCompletion()
        
        return EmptyDisposable
    }
    
    let dateUpdateSignal: Signal<Bool, NoError> = .single(true) |> then(dateSignal |> delay(1.0, queue: resourcesQueue) |> restart)
    
    let updateSignal = dateUpdateSignal |> filter {$0}
    
    return combineLatest(languageSignal, themeSignal, updateSignal |> deliverOnMainQueue) |> map {
        return Appearance(language: $0.0, presentation: $0.1)
    }
}

struct AppearanceWrapperEntry<E>: Comparable, Identifiable where E: Comparable, E:Identifiable {
    let entry: E
    let appearance: Appearance
    init(entry: E, appearance: Appearance) {
        self.entry = entry
        self.appearance = appearance
    }
    var stableId: AnyHashable {
        return entry.stableId
    }
}

func == <E>(lhs:AppearanceWrapperEntry<E>, rhs: AppearanceWrapperEntry<E>) -> Bool {
    return lhs.entry == rhs.entry && lhs.appearance == rhs.appearance
}
func < <E>(lhs:AppearanceWrapperEntry<E>, rhs: AppearanceWrapperEntry<E>) -> Bool {
    return lhs.entry < rhs.entry
}

