//
//  CallSettingsModalController.swift
//  Telegram
//
//  Created by Mikhail Filimonov on 21/02/2019.
//  Copyright © 2019 Telegram. All rights reserved.
//

import Cocoa
import TelegramCoreMac
import SwiftSignalKitMac
import PostboxMac
import TGUIKit


private final class CallSettingsArguments {
    let updateInputDevice: (String?)->Void
    let updateOutputDevice: (String?)->Void
    let muteSound:(Bool)->Void
    init(updateInputDevice: @escaping(String?)->Void, updateOutputDevice: @escaping(String?)->Void, muteSound:@escaping(Bool)->Void) {
        self.updateInputDevice = updateInputDevice
        self.updateOutputDevice = updateOutputDevice
        self.muteSound = muteSound
    }
}

private let _id_output_device = InputDataIdentifier("_id_output_device")
private let _id_input_device = InputDataIdentifier("_id_input_device")

private let _id_mute_sounds = InputDataIdentifier("_id_mute_sounds")
private let _id_open_settings = InputDataIdentifier("_id_open_settings")


private func callSettingsEntries(state: VoiceCallSettings, arguments: CallSettingsArguments, inputDevices: [AudioDevice], outputDevices: [AudioDevice]) -> [InputDataEntry] {
    var entries: [InputDataEntry] = []
    
    var sectionId: Int32 = 0
    var index: Int32 = 0
    
    
    entries.append(.sectionId(sectionId))
    sectionId += 1
    
    
    entries.append(InputDataEntry.desc(sectionId: sectionId, index: index, text: .plain(L10n.callSettingsOutputTitle), color: theme.colors.grayText, detectBold: false))
    index += 1

    let currentOutput = outputDevices.first(where: {$0.deviceId == state.outputDeviceId}) ?? inputDevices.first!

    let outputDevices = outputDevices.map { device -> SPopoverItem in
        return SPopoverItem(device.deviceName, {
            arguments.updateOutputDevice(device.deviceId)
        })
    }
    
    entries.append(InputDataEntry.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_output_device, data: InputDataGeneralData(name: L10n.callSettingsOutputText, color: theme.colors.text, icon: nil, type: .contextSelector(currentOutput.deviceName, outputDevices))))
    index += 1
    
    entries.append(.sectionId(sectionId))
    sectionId += 1
    
    entries.append(InputDataEntry.desc(sectionId: sectionId, index: index, text: .plain(L10n.callSettingsInputTitle), color: theme.colors.grayText, detectBold: false))
    index += 1
    
    
    let currentInput = inputDevices.first(where: {$0.deviceId == state.inputDeviceId}) ?? inputDevices.first!
    
    let inputDevices = inputDevices.map { device -> SPopoverItem in
        return SPopoverItem(device.deviceName, {
            arguments.updateInputDevice(device.deviceId)
        })
    }
    
    
    entries.append(InputDataEntry.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_input_device, data: InputDataGeneralData(name: L10n.callSettingsInputText, color: theme.colors.text, icon: nil, type: .contextSelector(currentInput.deviceName, inputDevices))))
    index += 1
    
    
    entries.append(.sectionId(sectionId))
    sectionId += 1
    
    
    entries.append(InputDataEntry.desc(sectionId: sectionId, index: index, text: .plain(L10n.callSettingsOtherSettingsTitle), color: theme.colors.grayText, detectBold: false))
    index += 1
    
    #if !APP_STORE
    entries.append(InputDataEntry.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_mute_sounds, data: InputDataGeneralData(name: L10n.callSettingsMuteSound, color: theme.colors.text, icon: nil, type: .switchable(state.muteSounds), action: {
        arguments.muteSound(!state.muteSounds)
    })))
    index += 1
    #endif
    entries.append(InputDataEntry.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_open_settings, data: InputDataGeneralData(name: L10n.callSettingsOpenSystemPreferences, color: theme.colors.text, icon: nil, type: .next, action: {
        openSystemSettings(.microphone)
    })))
    index += 1

    entries.append(.sectionId(sectionId))
    sectionId += 1
    
    
    return entries
}

private func inputDevices() -> Signal<[AudioDevice], NoError> {
    return Signal { subscriber in
        subscriber.putNext(CallBridge.inputDevices())
        subscriber.putCompletion()
        return ActionDisposable {
        }
    }
}
private func outputDevices() -> Signal<[AudioDevice], NoError> {
    return Signal { subscriber in
        subscriber.putNext(CallBridge.outputDevices())
        subscriber.putCompletion()
        return ActionDisposable {
            
        }
    }
}
func CallSettingsModalController(_ sharedContext: SharedAccountContext) -> InputDataController {

    
    let arguments = CallSettingsArguments(updateInputDevice: { id in
        _ = updateVoiceCallSettingsSettingsInteractively(accountManager: sharedContext.accountManager, { $0.withUpdatedInputDeviceId(id) }).start()
    }, updateOutputDevice: { id in
        _ = updateVoiceCallSettingsSettingsInteractively(accountManager: sharedContext.accountManager, { $0.withUpdatedOutputDeviceId(id) }).start()
    }, muteSound: { value in
        _ = updateVoiceCallSettingsSettingsInteractively(accountManager: sharedContext.accountManager, { $0.withUpdatedMuteSounds(value) }).start()
    })
    
    let signal = combineLatest(voiceCallSettings(sharedContext.accountManager), inputDevices(), outputDevices()) |> map { value, inputDevices, outputDevices in
        return callSettingsEntries(state: value, arguments: arguments, inputDevices: inputDevices, outputDevices: outputDevices)
    }
    return InputDataController(dataSignal: signal |> map { InputDataSignalValue(entries: $0) }, title: L10n.callSettingsTitle)
}
