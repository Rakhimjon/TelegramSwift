//
//  FileUtils.swift
//  Telegram-Mac
//
//  Created by keepcoder on 17/09/16.
//  Copyright © 2016 Telegram. All rights reserved.
//

import Cocoa
import SwiftSignalKitMac
import TelegramCoreMac
import PostboxMac
import TGUIKit
import AVFoundation
import Accelerate


func chatMessageFileStatus(account: Account, file: TelegramMediaFile, approximateSynchronousValue: Bool = false) -> Signal<MediaResourceStatus, NoError> {
    if let _ = file.resource as? LocalFileReferenceMediaResource {
        return .single(.Local)
    }
    return account.postbox.mediaBox.resourceStatus(file.resource, approximateSynchronousValue: approximateSynchronousValue)
}

func chatMessageFileInteractiveFetched(account: Account, fileReference: FileMediaReference) -> Signal<FetchResourceSourceType, NoError> {
    return fetchedMediaResource(postbox: account.postbox, reference: fileReference.resourceReference(fileReference.media.resource), statsCategory: .file, reportResultStatus: true) |> `catch` { _ in return .complete() }  //account.postbox.mediaBox.fetchedResource(file.resource, tag: TelegramMediaResourceFetchTag(statsCategory: .file), implNext: true)
}

func chatMessageFileCancelInteractiveFetch(account: Account, file: TelegramMediaFile) {
    account.postbox.mediaBox.cancelInteractiveResourceFetch(file.resource)
}

func largestRepresentationForPhoto(_ photo: TelegramMediaImage) -> TelegramMediaImageRepresentation? {
    return photo.representationForDisplayAtSize(NSMakeSize(1280.0, 1280.0))
}

func smallestImageRepresentation(_ representation:[TelegramMediaImageRepresentation]) -> TelegramMediaImageRepresentation? {
    return representation.first
}


//
func chatMessagePhotoDatas(postbox: Postbox, imageReference: ImageMediaReference, fullRepresentationSize: CGSize = CGSize(width: 1280.0, height: 1280.0), autoFetchFullSize: Bool = false, tryAdditionalRepresentations: Bool = false, synchronousLoad: Bool = false, secureIdAccessContext: SecureIdAccessContext? = nil) -> Signal<(Atomic<Data?>, Atomic<Data?>, Bool), NoError> {
    if let smallestRepresentation = smallestImageRepresentation(imageReference.media.representations), let largestRepresentation = imageReference.media.representationForDisplayAtSize(fullRepresentationSize) {
        
        
        let maybeFullSize = postbox.mediaBox.resourceData(largestRepresentation.resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: synchronousLoad)

        let signal = maybeFullSize
            |> take(1)
            |> mapToSignal { maybeData -> Signal<(Atomic<Data?>, Atomic<Data?>, Bool), NoError> in
                if maybeData.complete {
                    let loadedData: Data?
                    if largestRepresentation.resource is EncryptedMediaResource, let secureIdAccessContext = secureIdAccessContext {
                        loadedData = decryptedResourceData(data: maybeData, resource: largestRepresentation.resource, params: secureIdAccessContext)
                    } else {
                        loadedData = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                    }
                    return .single((Atomic(value: nil), Atomic(value: loadedData), true))
                } else {


                    let decodedThumbnailData = imageReference.media.immediateThumbnailData.flatMap(decodeTinyThumbnail)
                    let fetchedThumbnail: Signal<FetchResourceSourceType, NoError>
                    if let _ = decodedThumbnailData {
                        fetchedThumbnail = .complete()
                    } else {
                        fetchedThumbnail = fetchedMediaResource(postbox: postbox, reference: imageReference.resourceReference(smallestRepresentation.resource), statsCategory: .image) |> `catch` { _ in return .complete() }
                    }
                    let fetchedFullSize = fetchedMediaResource(postbox: postbox, reference: imageReference.resourceReference(largestRepresentation.resource), statsCategory: .image)

                    let anyThumbnail: [Signal<MediaResourceData, NoError>]
                    if tryAdditionalRepresentations {
                        anyThumbnail = imageReference.media.representations.filter({ representation in
                            return representation != largestRepresentation
                        }).map({ representation -> Signal<MediaResourceData, NoError> in
                            return postbox.mediaBox.resourceData(representation.resource)
                                |> take(1)
                        })
                    } else {
                        anyThumbnail = []
                    }

                    let mainThumbnail = Signal<Atomic<Data?>, NoError> { subscriber in
                        if let decodedThumbnailData = decodedThumbnailData {
                            subscriber.putNext(Atomic(value: decodedThumbnailData))
                            subscriber.putCompletion()
                            return EmptyDisposable
                        } else {
                            let fetchedDisposable = fetchedThumbnail.start()
                            let thumbnailDisposable = postbox.mediaBox.resourceData(smallestRepresentation.resource, attemptSynchronously: synchronousLoad).start(next: { next in
                                subscriber.putNext(Atomic(value: next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])))
                            }, error: subscriber.putError, completed: subscriber.putCompletion)

                            return ActionDisposable {
                                fetchedDisposable.dispose()
                                thumbnailDisposable.dispose()
                            }
                        }
                    }

                    let thumbnail = combineLatest(anyThumbnail)
                        |> mapToSignal { thumbnails -> Signal<Atomic<Data?>, NoError> in
                            for thumbnail in thumbnails {
                                if thumbnail.size != 0, let data = try? Data(contentsOf: URL(fileURLWithPath: thumbnail.path), options: []) {
                                    return .single(Atomic(value: data))
                                }
                            }
                            return mainThumbnail
                    }

                    let fullSizeData: Signal<(Atomic<Data?>, Bool), NoError>

                    if autoFetchFullSize {
                        fullSizeData = Signal<(Atomic<Data?>, Bool), NoError> { subscriber in
                            let fetchedFullSizeDisposable = fetchedFullSize.start()
                            let fullSizeDisposable = postbox.mediaBox.resourceData(largestRepresentation.resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: synchronousLoad).start(next: { next in
                                subscriber.putNext((Atomic(value: next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])), next.complete))
                            }, error: subscriber.putError, completed: subscriber.putCompletion)

                            return ActionDisposable {
                                fetchedFullSizeDisposable.dispose()
                                fullSizeDisposable.dispose()
                            }
                        }
                    } else {
                        fullSizeData = postbox.mediaBox.resourceData(largestRepresentation.resource, option: .complete(waitUntilFetchStatus: false), attemptSynchronously: synchronousLoad)
                            |> map { next -> (Atomic<Data?>, Bool) in
                                return (Atomic(value: next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])), next.complete)
                        }
                    }


                    return thumbnail
                        |> mapToSignal { thumbnailData in
                            if let _ = thumbnailData.with({$0}) {
                                return fullSizeData
                                    |> map { (fullSizeData, complete) in
                                        return (thumbnailData, fullSizeData, complete)
                                }
                            } else {
                                return .single((thumbnailData, Atomic(value: nil), false))
                            }
                    }
                }
            }
            |> distinctUntilChanged(isEqual: { lhs, rhs in
                if (lhs.0.with {$0} == nil && lhs.1.with {$0} == nil) && (rhs.0.with {$0} == nil && rhs.1.with {$0} == nil) {
                    return true
                } else {
                    return false
                }
            })

        return signal
    } else {
        return .never()
    }
}


//
//private func chatMessagePhotoDatas(postbox: account.postbox, imageReference: ImageMediaReference, fullRepresentationSize: CGSize = CGSize(width: 1280.0, height: 1280.0), autoFetchFullSize: Bool = false, secureIdAccessContext: SecureIdAccessContext? = nil) -> Signal<(Atomic<Data?>, Atomic<Data?>, Bool), NoError> {
//    if let smallestRepresentation = smallestImageRepresentation(imageReference.media.representations), let largestRepresentation = imageReference.media.representationForDisplayAtSize(fullRepresentationSize) {
//        let maybeFullSize = account.postbox.mediaBox.resourceData(largestRepresentation.resource)
//        // |> take(1)
//        let signal = maybeFullSize |> mapToSignal { maybeData -> Signal<(Atomic<Data?>, Atomic<Data?>, Bool), NoError> in
//            if maybeData.complete {
//                let loadedData: Data?
//                if largestRepresentation.resource is EncryptedMediaResource, let secureIdAccessContext = secureIdAccessContext {
//                    loadedData = decryptedResourceData(data: maybeData, resource: largestRepresentation.resource, params: secureIdAccessContext)
//                } else {
//                    loadedData = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
//                }
//
//                return .single((Atomic(value: nil), Atomic(value: loadedData), true))
//            } else {
//
//                let fetchedThumbnail = fetchedMediaResource(postbox: account.postbox, reference: imageReference.resourceReference(smallestRepresentation.resource), statsCategory: .image)//account.postbox.mediaBox.fetchedResource(smallestRepresentation.resource, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
//                let fetchedFullSize = fetchedMediaResource(postbox: account.postbox, reference: imageReference.resourceReference(largestRepresentation.resource), statsCategory: .image)//account.postbox.mediaBox.fetchedResource(largestRepresentation.resource, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
//
//                let thumbnail = Signal<Data?, NoError> { subscriber in
//                    let fetchedDisposable = fetchedThumbnail.start()
//                    let thumbnailDisposable = account.postbox.mediaBox.resourceData(smallestRepresentation.resource).start(next: { next in
//                        subscriber.putNext(next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: []))
//                        }, error: subscriber.putError, completed: subscriber.putCompletion)
//
//                    return ActionDisposable {
//                        fetchedDisposable.dispose()
//                        thumbnailDisposable.dispose()
//                    }
//                }
//
//                let fullSizeData: Signal<(Atomic<Data?>, Bool), NoError>
//
//                if autoFetchFullSize {
//                    fullSizeData = Signal<(Atomic<Data?>, Bool), NoError> { subscriber in
//                        let fetchedFullSizeDisposable = fetchedFullSize.start()
//                        let fullSizeDisposable = account.postbox.mediaBox.resourceData(largestRepresentation.resource).start(next: { next in
//                            subscriber.putNext((Atomic(value: next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])), next.complete))
//                            }, error: subscriber.putError, completed: subscriber.putCompletion)
//
//                        return ActionDisposable {
//                            fetchedFullSizeDisposable.dispose()
//                            fullSizeDisposable.dispose()
//                        }
//                    }
//                } else {
//                    fullSizeData = account.postbox.mediaBox.resourceData(largestRepresentation.resource)
//                        |> map { next -> (Atomic<Data?>, Bool) in
//                            return (Atomic(value: next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])), next.complete)
//                    }
//                }
//
//
//                return thumbnail |> mapToSignal { thumbnailData in
//                    return fullSizeData |> map { (fullSizeData, complete) in
//                        return (thumbnailData, fullSizeData, complete)
//                    }
//                }
//            }
//            }
//
//        return signal
//    } else {
//        return .never()
//    }
//}

private func chatMessageWebFilePhotoDatas(account: Account, photo: TelegramMediaWebFile, synchronousLoad: Bool = false) -> Signal<(Atomic<Data?>, Bool), NoError> {
    let maybeFullSize = account.postbox.mediaBox.resourceData(photo.resource, attemptSynchronously: synchronousLoad)
    
    let signal = maybeFullSize |> take(1) |> mapToSignal { maybeData -> Signal<(Atomic<Data?>, Bool), NoError> in
        if maybeData.complete {
            let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
            
            return .single((Atomic(value: loadedData), true))
        } else {
            let fullSizeData: Signal<(Atomic<Data?>, Bool), NoError>
            
            fullSizeData = account.postbox.mediaBox.resourceData(photo.resource, attemptSynchronously: synchronousLoad)
                |> map { next -> (Atomic<Data?>, Bool) in
                    return (Atomic(value: next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])), next.complete)
            }
            
            return fullSizeData |> map { resource in
                return (resource.0, resource.1)
            }
        }
    } |> filter({ $0.0.with {$0} != nil })
    
    return signal
}



private func chatMessageFileDatas(account: Account, fileReference: FileMediaReference, pathExtension: String? = nil, progressive: Bool = false, justThumbail: Bool = false, synchronousLoad: Bool = false) -> Signal<(Atomic<Data?>, String?, Bool), NoError> {
    if let smallestRepresentation = smallestImageRepresentation(fileReference.media.previewRepresentations) {
        let thumbnailResource = smallestRepresentation.resource
        let fullSizeResource = largestImageRepresentation(fileReference.media.previewRepresentations)?.resource ?? smallestRepresentation.resource
        
        let maybeFullSize = account.postbox.mediaBox.resourceData(fullSizeResource, pathExtension: pathExtension, attemptSynchronously: synchronousLoad)
        
        let signal = maybeFullSize |> mapToSignal { maybeData -> Signal<(Atomic<Data?>, String?, Bool), NoError> in
            
           if maybeData.complete && !justThumbail {
            return .single((Atomic(value: nil), maybeData.path, true))
            } else {
                let fetchedThumbnail = fetchedMediaResource(postbox: account.postbox, reference: fileReference.resourceReference(thumbnailResource))
                
                let thumbnail = Signal<Atomic<Data?>, NoError> { subscriber in
                    let fetchedDisposable = fetchedThumbnail.start()
                    let thumbnailDisposable = account.postbox.mediaBox.resourceData(thumbnailResource, pathExtension: pathExtension, attemptSynchronously: synchronousLoad).start(next: { next in
                        subscriber.putNext(Atomic(value: next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])))
                    }, error: subscriber.putError, completed: subscriber.putCompletion)
                    
                    return ActionDisposable {
                        fetchedDisposable.dispose()
                        thumbnailDisposable.dispose()
                    }
                }
                
                
                let fullSizeDataAndPath = account.postbox.mediaBox.resourceData(fullSizeResource, option: !progressive ? .complete(waitUntilFetchStatus: false) : .incremental(waitUntilFetchStatus: false), attemptSynchronously: synchronousLoad) |> map { next -> (String?, Bool) in
                    return (next.size == 0 ? nil : next.path, next.complete)
                }
            
                
                return thumbnail |> mapToSignal { thumbnailData in
                    return fullSizeDataAndPath |> take(1) |> map { dataPath, complete in
                        return (thumbnailData, dataPath, complete)
                    }
                } |> then(Signal({ subscriber -> Disposable in
                    if !maybeData.complete, let fullSizeResource = fullSizeResource as? LocalFileReferenceMediaResource {
                        subscriber.putNext((Atomic(value: justThumbail ? try? Data(contentsOf: URL(fileURLWithPath: fullSizeResource.localFilePath)) : nil), fullSizeResource.localFilePath, true))
                    }
                    subscriber.putCompletion()
                    return EmptyDisposable
                }))
            }
            } |> filter({ $0.0.with {$0} != nil || $0.1 != nil })
        
        return signal
    } else {
        return .never()
    }
}


func chatGalleryPhoto(account: Account, imageReference: ImageMediaReference, toRepresentationSize:NSSize = NSMakeSize(1280, 1280), scale:CGFloat, secureIdAccessContext: SecureIdAccessContext? = nil, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> CGImage?, NoError> {
    let signal = chatMessagePhotoDatas(postbox: account.postbox, imageReference: imageReference, fullRepresentationSize:toRepresentationSize, synchronousLoad: synchronousLoad, secureIdAccessContext: secureIdAccessContext)
    
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            
            let fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize).fitted(arguments.imageSize)
            
            let fullSizeData = fullSizeData.with {$0}
            let thumbnailData = thumbnailData.with {$0}
            
            if let fullSizeData = fullSizeData {
                
                
                
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    if let image = NSImage(data: fullSizeData)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        return image
                    }
                    
                 //   options.setValue(max(fittedSize.width * scale, fittedSize.height * scale) as NSNumber, forKey: kCGImageSourceThumbnailMaxPixelSize as String)
                    options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)
                    options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailWithTransform as String)
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, options), let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                        return image
                    }
                    
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailWithTransform as String)
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        return image
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                return thumbnailContext.generateImage()
            }
            return generateImage(fittedSize, contextGenerator: { (size, ctx) in
                ctx.setFillColor(theme.colors.background.cgColor)
                ctx.fill(NSMakeRect(0, 0, size.width, size.height))
            })
            
        }
    }
}

func chatMessagePhoto(account: Account, imageReference: ImageMediaReference, toRepresentationSize:NSSize = NSMakeSize(1280, 1280), scale:CGFloat, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessagePhotoDatas(postbox: account.postbox, imageReference: imageReference, fullRepresentationSize: toRepresentationSize, synchronousLoad: synchronousLoad)
    
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale:scale, clear: true)
            
            let fullSizeData = fullSizeData.with {$0}
            let thumbnailData = thumbnailData.with {$0}
            
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize)
            switch arguments.resizeMode {
            case .none:
                break
            default:
                fittedSize = fittedSize.fitted(arguments.imageSize)
            }
            let fittedRect = CGRect(origin: CGPoint(x: floorToScreenPixels(scaleFactor: System.backingScale, drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0), y: floorToScreenPixels(scaleFactor: System.backingScale, drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0)), size: fittedSize)

            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options.setValue(max(fittedSize.width * context.scale, fittedSize.height * context.scale) as NSNumber, forKey: kCGImageSourceThumbnailMaxPixelSize as String)
                 //   options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                    
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: CGImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                
                let initialThumbnailContextFittingSize = fittedSize.fitted(CGSize(width: 90.0, height: 90.0))
                
                let thumbnailContextSize = thumbnailSize.aspectFitted(initialThumbnailContextFittingSize)
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlurMore(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                var thumbnailContextFittingSize = CGSize(width: floor(arguments.drawingSize.width * 0.5), height: floor(arguments.drawingSize.width * 0.5))
                if thumbnailContextFittingSize.width < 150.0 || thumbnailContextFittingSize.height < 150.0 {
                    thumbnailContextFittingSize = thumbnailContextFittingSize.aspectFilled(CGSize(width: 150.0, height: 150.0))
                }
                
                if thumbnailContextFittingSize.width > thumbnailContextSize.width {
                    let additionalContextSize = thumbnailContextFittingSize
                    let additionalBlurContext = DrawingContext(size: additionalContextSize, scale: 1.0)
                    additionalBlurContext.withFlippedContext { c in
                        c.interpolationQuality = .default
                        if let image = thumbnailContext.generateImage() {
                            c.draw(image, in: CGRect(origin: CGPoint(), size: additionalContextSize))
                        }
                    }
                    telegramFastBlur(Int32(additionalContextSize.width), Int32(additionalContextSize.height), Int32(additionalBlurContext.bytesPerRow), additionalBlurContext.bytes)
                    blurredThumbnailImage = additionalBlurContext.generateImage()
                } else {
                    blurredThumbnailImage = thumbnailContext.generateImage()
                }
            }

            
            context.withContext(isHighQuality: fullSizeImage != nil, { c in
                c.setBlendMode(.copy)
                if arguments.boundingSize != arguments.imageSize {
                    switch arguments.resizeMode {
                    case .blurBackground:
                        let blurSourceImage = thumbnailImage ?? fullSizeImage
                        
                        if let fullSizeImage = blurSourceImage {
                            let thumbnailSize = CGSize(width: fullSizeImage.width, height: fullSizeImage.height)
                            let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 74.0, height: 74.0))
                            let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                            thumbnailContext.withFlippedContext { c in
                                c.interpolationQuality = .none
                                c.draw(fullSizeImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                            }
                           // telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                            telegramFastBlurMore(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                            
                            if let blurredImage = thumbnailContext.generateImage() {
                                let filledSize = thumbnailSize.aspectFilled(arguments.drawingRect.size)
                                c.interpolationQuality = .medium
                                c.draw(blurredImage, in: CGRect(origin: CGPoint(x: arguments.drawingRect.minX + (arguments.drawingRect.width - filledSize.width) / 2.0, y: arguments.drawingRect.minY + (arguments.drawingRect.height - filledSize.height) / 2.0), size: filledSize))
                                c.setBlendMode(.normal)
                                c.setFillColor(theme.colors.background.withAlphaComponent(0.5).cgColor)
                                c.fill(arguments.drawingRect)
                                c.setBlendMode(.copy)
                            }
                        } else {
                            c.fill(arguments.drawingRect)
                        }
                    case let .fill(color):
                        c.setFillColor(color.cgColor)
                        c.fill(arguments.drawingRect)
                    case .fillTransparent:
                        c.setFillColor(theme.colors.transparentBackground.cgColor)
                        c.fill(arguments.drawingRect)
                    case .none:
                        break
                    case .imageColor:
                        break
                    }
                }
                
                if let blurredThumbnailImage = blurredThumbnailImage {
                    c.interpolationQuality = .low
                    c.draw(blurredThumbnailImage, in: fittedRect)
                    c.setBlendMode(.normal)
                }
                
                
                if let fullSizeImage = fullSizeImage {
                    c.interpolationQuality = .low
                    c.draw(fullSizeImage, in: fittedRect)
                }

            })
            
            
            addCorners(context, arguments: arguments, scale:scale)
            
            return context
        }
    }
}

func chatMessageWebFilePhoto(account: Account, photo: TelegramMediaWebFile, toRepresentationSize:NSSize = NSMakeSize(1280, 1280), scale:CGFloat, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessageWebFilePhotoDatas(account: account, photo: photo, synchronousLoad: synchronousLoad)
    
    return signal |> map { (fullSizeData, fullSizeComplete) in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale:scale, clear: true)
            
            let fullSizeData = fullSizeData.with {$0}
            
            let drawingRect = arguments.drawingRect
            let fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize).fitted(arguments.imageSize)
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options.setValue(max(fittedSize.width * context.scale, fittedSize.height * context.scale) as NSNumber, forKey: kCGImageSourceThumbnailMaxPixelSize as String)
                    options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                    
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                }
            }
            
           
            
            context.withContext(isHighQuality: fullSizeImage != nil, { c in
                c.setBlendMode(.copy)
                if arguments.boundingSize != arguments.imageSize {
                    c.setFillColor(theme.colors.grayBackground.cgColor)
                    c.fill(arguments.drawingRect)
                }
                
                c.setBlendMode(.copy)
                if let fullSizeImage = fullSizeImage {
                    c.interpolationQuality = .medium
                    c.draw(fullSizeImage, in: fittedRect)
                }
                
            })
            
            
            addCorners(context, arguments: arguments, scale:scale)
            
            return context
        }
    }
}


enum StickerDatasType {
    case thumb
    case small
    case chatMessage
    case full
}

func chatMessageStickerResource(file: TelegramMediaFile, small: Bool) -> MediaResource {
    let resource: MediaResource
    if small, let smallest = largestImageRepresentation(file.previewRepresentations) {
        resource = smallest.resource
    } else {
        resource = file.resource
    }
    return resource
}



private func chatMessageStickerDatas(postbox: Postbox, file: TelegramMediaFile, small: Bool, fetched: Bool, onlyFullSize: Bool, synchronousLoad: Bool) -> Signal<(Data?, Data?, Bool), NoError> {
    let thumbnailResource = chatMessageStickerResource(file: file, small: true)
    let resource = chatMessageStickerResource(file: file, small: small)
    
    let maybeFetched = postbox.mediaBox.cachedResourceRepresentation(resource, representation: CachedStickerAJpegRepresentation(size: small ? CGSize(width: 160.0, height: 160.0) : nil), complete: false, fetch: false, attemptSynchronously: synchronousLoad)
    
    return maybeFetched
        |> take(1)
        |> mapToSignal { maybeData in
            if maybeData.complete {
                let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                
                return .single((nil, loadedData, true))
            } else {
                let thumbnailData = postbox.mediaBox.cachedResourceRepresentation(thumbnailResource, representation: CachedStickerAJpegRepresentation(size: nil), complete: false)
                let fullSizeData = postbox.mediaBox.cachedResourceRepresentation(resource, representation: CachedStickerAJpegRepresentation(size: small ? CGSize(width: 160.0, height: 160.0) : nil), complete: onlyFullSize)
                    |> map { next in
                        return (next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: .mappedIfSafe), next.complete)
                }
                
                return Signal { subscriber in
                    var fetch: Disposable?
                    if fetched {
                        fetch = fetchedMediaResource(postbox: postbox, reference: stickerPackFileReference(file).resourceReference(resource)).start()
                    }
                    
                    var fetchThumbnail: Disposable?
                    if !thumbnailResource.id.isEqual(to: resource.id) {
                        fetchThumbnail = fetchedMediaResource(postbox: postbox, reference: stickerPackFileReference(file).resourceReference(thumbnailResource)).start()
                    }
                    let disposable = (combineLatest(thumbnailData, fullSizeData)
                        |> map { thumbnailData, fullSizeData -> (Data?, Data?, Bool) in
                            return (thumbnailData.complete ? try? Data(contentsOf: URL(fileURLWithPath: thumbnailData.path)) : nil, fullSizeData.0, fullSizeData.1)
                        }).start(next: { next in
                            subscriber.putNext(next)
                        }, error: { error in
                            subscriber.putError(error)
                        }, completed: {
                            subscriber.putCompletion()
                        })
                    
                    return ActionDisposable {
                        fetch?.dispose()
                        fetchThumbnail?.dispose()
                        disposable.dispose()
                    }
                }
            }
    }
}





private func chatMessageStickerThumbnailData(postbox: Postbox, file: TelegramMediaFile, synchronousLoad: Bool) -> Signal<Data?, NoError> {
    let thumbnailResource = chatMessageStickerResource(file: file, small: true)
    
    let maybeFetched = postbox.mediaBox.cachedResourceRepresentation(thumbnailResource, representation: CachedStickerAJpegRepresentation(size: nil), complete: false, fetch: false, attemptSynchronously: synchronousLoad)
    
    return maybeFetched
        |> take(1)
        |> mapToSignal { maybeData in
            if maybeData.complete {
                let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                return .single(loadedData)
            } else {
                let thumbnailData = postbox.mediaBox.cachedResourceRepresentation(thumbnailResource, representation: CachedStickerAJpegRepresentation(size: nil), complete: false)
                
                return Signal { subscriber in
                    var fetchThumbnail = fetchedMediaResource(postbox: postbox, reference: stickerPackFileReference(file).resourceReference(thumbnailResource)).start()
                    
                    let disposable = (thumbnailData
                        |> map { thumbnailData -> Data? in
                            return thumbnailData.complete ? try? Data(contentsOf: URL(fileURLWithPath: thumbnailData.path)) : nil
                        }).start(next: { next in
                            subscriber.putNext(next)
                        }, error: { error in
                            subscriber.putError(error)
                        }, completed: {
                            subscriber.putCompletion()
                        })
                    
                    return ActionDisposable {
                        fetchThumbnail.dispose()
                        disposable.dispose()
                    }
                }
            }
    }
}


public func chatMessageSticker(postbox: Postbox, file: TelegramMediaFile, small: Bool, scale: CGFloat, fetched: Bool = false, onlyFullSize: Bool = false, thumbnail: Bool = false, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal: Signal<(Data?, Data?, Bool), NoError>
    if thumbnail {
        signal = chatMessageStickerThumbnailData(postbox: postbox, file: file, synchronousLoad: synchronousLoad)
            |> map { data -> (Data?, Data?, Bool) in
                return (data, nil, false)
        }
    } else {
        signal = chatMessageStickerDatas(postbox: postbox, file: file, small: small, fetched: fetched, onlyFullSize: onlyFullSize, synchronousLoad: synchronousLoad)
    }
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale: scale, clear: arguments.emptyColor == nil)
            
            let drawingRect = arguments.drawingRect
            let fittedSize = arguments.imageSize
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            //let fittedRect = arguments.drawingRect
            
            var fullSizeImage: (CGImage, CGImage)?
            if let fullSizeData = fullSizeData, fullSizeComplete {
                if let image = imageFromAJpeg(data: fullSizeData) {
                    fullSizeImage = image
                }
            }
            
            var thumbnailImage: (CGImage, CGImage)?
            if fullSizeImage == nil, let thumbnailData = thumbnailData {
                if let image = imageFromAJpeg(data: thumbnailData) {
                    thumbnailImage = image
                }
            }
            
            var blurredThumbnailImage: CGImage?
            let thumbnailInset: CGFloat = 10.0
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = thumbnailImage.0.size
                var thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailDrawingSize = thumbnailContextSize
                thumbnailContextSize.width += thumbnailInset * 2.0
                thumbnailContextSize.height += thumbnailInset * 2.0
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0, clear: true)
                thumbnailContext.withFlippedContext(isHighQuality: false, { c in
                    let cgImage = thumbnailImage.0
                    let cgImageAlpha = thumbnailImage.1
                    c.setBlendMode(.normal)
                    c.interpolationQuality = .medium
                    
                    let mask = CGImage(maskWidth: cgImageAlpha.width, height: cgImageAlpha.height, bitsPerComponent: cgImageAlpha.bitsPerComponent, bitsPerPixel: cgImageAlpha.bitsPerPixel, bytesPerRow: cgImageAlpha.bytesPerRow, provider: cgImageAlpha.dataProvider!, decode: nil, shouldInterpolate: true)
                    
                    c.draw(cgImage.masking(mask!)!, in: CGRect(origin: CGPoint(x: thumbnailInset, y: thumbnailInset), size: thumbnailDrawingSize))
                })
                stickerThumbnailAlphaBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                blurredThumbnailImage = thumbnailContext.generateImage()
            }
            
            context.withFlippedContext(isHighQuality: fullSizeImage != nil, { c in
                if let color = arguments.emptyColor {
                    c.setBlendMode(.normal)
                    c.setFillColor(color.cgColor)
                    c.fill(drawingRect)
                } else {
                    c.setBlendMode(.copy)
                }
                
                if let blurredThumbnailImage = blurredThumbnailImage {
                    c.interpolationQuality = .low
                    let thumbnailScaledInset = thumbnailInset * (fittedRect.width / blurredThumbnailImage.size.width)
                    c.draw(blurredThumbnailImage, in: fittedRect.insetBy(dx: -thumbnailScaledInset, dy: -thumbnailScaledInset))
                }
                
                if let fullSizeImage = fullSizeImage {
                    let cgImage = fullSizeImage.0
                    let cgImageAlpha = fullSizeImage.1
                    c.setBlendMode(.normal)
                    c.interpolationQuality = .medium
                    
                    let mask = CGImage(maskWidth: cgImageAlpha.width, height: cgImageAlpha.height, bitsPerComponent: cgImageAlpha.bitsPerComponent, bitsPerPixel: cgImageAlpha.bitsPerPixel, bytesPerRow: cgImageAlpha.bytesPerRow, provider: cgImageAlpha.dataProvider!, decode: nil, shouldInterpolate: true)
                    
                    c.draw(cgImage.masking(mask!)!, in: fittedRect)
                }
            })
            
            return context
        }
    }
}




private func chatMessageStickerPackThumbnailData(postbox: Postbox, representation: TelegramMediaImageRepresentation, synchronousLoad: Bool) -> Signal<Data?, NoError> {
    let resource = representation.resource
    
    let maybeFetched = postbox.mediaBox.cachedResourceRepresentation(resource, representation: CachedStickerAJpegRepresentation(size: CGSize(width: 160.0, height: 160.0)), complete: false, fetch: false, attemptSynchronously: synchronousLoad)
    
    return maybeFetched
        |> take(1)
        |> mapToSignal { maybeData in
            if maybeData.complete {
                let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                return .single(loadedData)
            } else {
                let fullSizeData = postbox.mediaBox.cachedResourceRepresentation(resource, representation: CachedStickerAJpegRepresentation(size: CGSize(width: 160.0, height: 160.0)), complete: false)
                    |> map { next in
                        return ((next.size == 0 || !next.complete) ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: .mappedIfSafe), next.complete)
                }
                
                return Signal { subscriber in
                    let fetch: Disposable? = nil
                    let disposable = fullSizeData.start(next: { next in
                        subscriber.putNext(next.0)
                    }, error: { error in
                        subscriber.putError(error)
                    }, completed: {
                        subscriber.putCompletion()
                    })
                    
                    return ActionDisposable {
                        fetch?.dispose()
                        disposable.dispose()
                    }
                }
            }
    }
}





public func chatMessageStickerPackThumbnail(postbox: Postbox, representation: TelegramMediaImageRepresentation, scale: CGFloat, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessageStickerPackThumbnailData(postbox: postbox, representation: representation, synchronousLoad: synchronousLoad)
    
    return signal
        |> map { fullSizeData in
            return { arguments in
                let context = DrawingContext(size: arguments.drawingSize, scale: scale, clear: arguments.emptyColor == nil)
                
                let drawingRect = arguments.drawingRect
                let fittedSize = arguments.imageSize
                let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
                
                var fullSizeImage: (CGImage, CGImage)?
                if let fullSizeData = fullSizeData {
                    if let image = imageFromAJpeg(data: fullSizeData) {
                        fullSizeImage = image
                    }
                }
                
                context.withFlippedContext { c in
                    if let color = arguments.emptyColor {
                        c.setBlendMode(.normal)
                        c.setFillColor(color.cgColor)
                        c.fill(drawingRect)
                    } else {
                        c.setBlendMode(.copy)
                    }
                    
                    if let fullSizeImage = fullSizeImage {
                        let cgImage = fullSizeImage.0
                        let cgImageAlpha = fullSizeImage.1
                        c.setBlendMode(.normal)
                        c.interpolationQuality = .medium
                        
                        let mask = CGImage(maskWidth: cgImageAlpha.width, height: cgImageAlpha.height, bitsPerComponent: cgImageAlpha.bitsPerComponent, bitsPerPixel: cgImageAlpha.bitsPerPixel, bytesPerRow: cgImageAlpha.bytesPerRow, provider: cgImageAlpha.dataProvider!, decode: nil, shouldInterpolate: true)
                        
                        c.draw(cgImage.masking(mask!)!, in: fittedRect)
                    }
                }
                
                return context
            }
    }
}



func chatWebpageSnippetPhotoData(account: Account, imageRefence: ImageMediaReference, small:Bool) -> Signal<Data?, NoError> {
    if let closestRepresentation = (small ? imageRefence.media.representationForDisplayAtSize(CGSize(width: 120.0, height: 120.0)) : largestImageRepresentation(imageRefence.media.representations)) {
        let resourceData = account.postbox.mediaBox.resourceData(closestRepresentation.resource) |> map { next in
            return next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: .mappedIfSafe)
        }
        
        return Signal { subscriber in
            let disposable = DisposableSet()
            disposable.add(resourceData.start(next: { data in
                subscriber.putNext(data)
                }, error: { error in
                    subscriber.putError(error)
                }, completed: {
                    subscriber.putCompletion()
            }))
            //account.postbox.mediaBox.fetchedResource(closestRepresentation.resource, tag: TelegramMediaResourceFetchTag(statsCategory: .file)
            
            disposable.add(fetchedMediaResource(postbox: account.postbox, reference: imageRefence.resourceReference(closestRepresentation.resource), statsCategory: .file).start())
            return disposable
        }
    } else {
        return .never()
    }
}

func chatWebpageSnippetPhoto(account: Account, imageReference: ImageMediaReference, scale:CGFloat, small:Bool, synchronousLoad: Bool = false, secureIdAccessContext: SecureIdAccessContext? = nil) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessagePhotoDatas(postbox: account.postbox, imageReference: imageReference, synchronousLoad: synchronousLoad, secureIdAccessContext: secureIdAccessContext)
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale:scale, clear: true)
            
            let fullSizeData = fullSizeData.with {$0}
            let thumbnailData = thumbnailData.with {$0}
            
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize)
            switch arguments.resizeMode {
            case .none:
                break
            default:
                fittedSize = fittedSize.fitted(arguments.imageSize)
            }
            var fittedRect = CGRect(origin: CGPoint(x: floorToScreenPixels(scaleFactor: System.backingScale, drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0), y: floorToScreenPixels(scaleFactor: System.backingScale, drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0)), size: fittedSize)
//
//            let drawingRect = arguments.drawingRect
//            var fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize).fitted(arguments.imageSize)
//            var fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    //   options.setValue(max(fittedSize.width * context.scale, fittedSize.height * context.scale) as NSNumber, forKey: kCGImageSourceThumbnailMaxPixelSize as String)
                    options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                        switch arguments.resizeMode {
                        case .none:
                              fittedSize = image.backingSize.aspectFilled(arguments.boundingSize)//.fitted(image.backingSize)
                              fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
                        default:
                            break
                        }
                    }
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                        switch arguments.resizeMode {
                        case .none:
                            fittedSize = image.backingSize.aspectFilled(arguments.boundingSize)//.fitted(image.backingSize)
                            fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
                        default:
                            break
                        }
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: CGImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlurMore(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                blurredThumbnailImage = thumbnailContext.generateImage()
            }
            
            context.withFlippedContext(isHighQuality: fullSizeImage != nil, { c in
                c.setBlendMode(.copy)
                
                if arguments.boundingSize != arguments.imageSize {
                    switch arguments.resizeMode {
                    case .blurBackground:
                        let blurSourceImage = thumbnailImage ?? fullSizeImage
                        
                        if let fullSizeImage = blurSourceImage {
                            let thumbnailSize = CGSize(width: fullSizeImage.width, height: fullSizeImage.height)
                            let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 74.0, height: 74.0))
                            let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                            thumbnailContext.withFlippedContext { c in
                                c.interpolationQuality = .none
                                c.draw(fullSizeImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                            }
                            telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                            
                            if let blurredImage = thumbnailContext.generateImage() {
                                let filledSize = thumbnailSize.aspectFilled(arguments.drawingRect.size)
                                c.interpolationQuality = .low
                                c.draw(blurredImage, in: CGRect(origin: CGPoint(x: arguments.drawingRect.minX + (arguments.drawingRect.width - filledSize.width) / 2.0, y: arguments.drawingRect.minY + (arguments.drawingRect.height - filledSize.height) / 2.0), size: filledSize))
                                c.setBlendMode(.normal)
                                c.setFillColor(theme.colors.background.withAlphaComponent(0.5).cgColor)
                                c.fill(arguments.drawingRect)
                                c.setBlendMode(.copy)
                            }
                        } else {
                            c.setBlendMode(.normal)
                            c.setFillColor(theme.colors.grayForeground.cgColor)
                            c.fill(arguments.drawingRect)
                        }
                    case let .fill(color):
                        c.setBlendMode(.normal)
                        c.setFillColor(color.cgColor)
                        c.fill(arguments.drawingRect)
                    case .fillTransparent:
                        c.setBlendMode(.normal)
                        c.setFillColor(theme.colors.transparentBackground.cgColor)
                        c.fill(arguments.drawingRect)
                    case .none:
                        c.setBlendMode(.normal)
                        c.setFillColor(theme.colors.grayForeground.cgColor)
                        c.fill(arguments.drawingRect)
                    case .imageColor:
                        break
                    }
                }
                
                c.setBlendMode(.copy)
                if let cgImage = blurredThumbnailImage {
                    c.interpolationQuality = .low
                    c.draw(cgImage, in: fittedRect)
                    c.setBlendMode(.normal)
                }
                
                if let fullSizeImage = fullSizeImage {
                    c.interpolationQuality = .medium
                    c.draw(fullSizeImage, in: fittedRect)
                }
                
                if blurredThumbnailImage == nil && fullSizeImage == nil && arguments.boundingSize == arguments.imageSize {
                    c.setBlendMode(.normal)
                    c.setFillColor(theme.colors.grayForeground.cgColor)
                    c.fill(arguments.drawingRect)
                }
            })
            
            addCorners(context, arguments: arguments, scale:scale)
            
            return context
        }
    }
}



func chatMessagePhotoStatus(account: Account, photo: TelegramMediaImage, approximateSynchronousValue: Bool = false) -> Signal<MediaResourceStatus, NoError> {
    if let largestRepresentation = photo.representationForDisplayAtSize(NSMakeSize(1280, 1280)) {
        return account.postbox.mediaBox.resourceStatus(largestRepresentation.resource, approximateSynchronousValue: approximateSynchronousValue)
    } else {
        return .never()
    }
}

func chatMessagePhotoInteractiveFetched(account: Account, imageReference: ImageMediaReference, toRepresentationSize: NSSize = NSMakeSize(1280, 1280)) -> Signal<Void, NoError> {
    if let largestRepresentation = imageReference.media.representationForDisplayAtSize(toRepresentationSize) {
        return fetchedMediaResource(postbox: account.postbox, reference: imageReference.resourceReference(largestRepresentation.resource), statsCategory: .image) |> `catch` { _ in return .complete() } |> map {_ in}
    } else {
        return .never()
    }
}

func chatMessagePhotoCancelInteractiveFetch(account: Account, photo: TelegramMediaImage) {
    if let largestRepresentation = largestRepresentationForPhoto(photo) {
        return account.postbox.mediaBox.cancelInteractiveResourceFetch(largestRepresentation.resource)
    }
}

func fileInteractiveFetched(account: Account, fileReference: FileMediaReference) -> Signal<Void, NoError> {
    return fetchedMediaResource(postbox: account.postbox, reference: fileReference.resourceReference(fileReference.media.resource), statsCategory: .file) |> `catch` { _ in return .complete() } |> map {_ in} //account.postbox.mediaBox.fetchedResource(file.resource, tag: TelegramMediaResourceFetchTag(statsCategory: .file)) |> map {_ in}
}

func fileCancelInteractiveFetch(account: Account, file: TelegramMediaFile) {
    account.postbox.mediaBox.cancelInteractiveResourceFetch(file.resource)
}


public func blurImage(_ data:Data?, _ s:NSSize, cornerRadius:CGFloat = 0) -> CGImage? {
    
    var thumbnailImage: CGImage?
    if let idata = data, let imageSource = CGImageSourceCreateWithData(idata as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
        thumbnailImage = image
    }
    var blurredThumbnailImage: CGImage?

    if let thumbnailImage = thumbnailImage {
        let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
        let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 300.0, height: 300.0))
        let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
        thumbnailContext.withContext { ctx in
            ctx.interpolationQuality = .none
            
            ctx.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
        }
        telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
        
        blurredThumbnailImage = thumbnailContext.generateImage()

        if cornerRadius > 0 {
            
           let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 2.0)

            thumbnailContext.withContext({ (ctx) in
                let minx:CGFloat = 0, midx = thumbnailContextSize.width/2.0, maxx = thumbnailContextSize.width
                let miny:CGFloat = 0, midy = thumbnailContextSize.height/2.0, maxy = thumbnailContextSize.height
                
                ctx.move(to: NSMakePoint(minx, midy))
                ctx.addArc(tangent1End: NSMakePoint(minx, miny), tangent2End: NSMakePoint(midx, miny), radius: cornerRadius)
                ctx.addArc(tangent1End: NSMakePoint(maxx, miny), tangent2End: NSMakePoint(maxx, midy), radius: cornerRadius)
                ctx.addArc(tangent1End: NSMakePoint(maxx, maxy), tangent2End: NSMakePoint(midx, maxy), radius: cornerRadius)
                ctx.addArc(tangent1End: NSMakePoint(minx, maxy), tangent2End: NSMakePoint(minx, midy), radius: cornerRadius)
                
                ctx.closePath()
                ctx.clip()
   
                ctx.draw(blurredThumbnailImage!, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                
            })
            
            blurredThumbnailImage = thumbnailContext.generateImage()
        }
    }
    
    return blurredThumbnailImage
}



private func chatMessageVideoDatas(postbox: Postbox, fileReference: FileMediaReference, thumbnailSize: Bool = false, onlyFullSize: Bool = false, synchronousLoad: Bool = false) -> Signal<(Atomic<Data?>, Atomic<Data?>, Bool), NoError> {
    
    let fetchedFullSize = postbox.mediaBox.cachedResourceRepresentation(fileReference.media.resource, representation: thumbnailSize ? CachedScaledVideoFirstFrameRepresentation(size: CGSize(width: 160.0, height: 160.0)) : CachedVideoFirstFrameRepresentation(), complete: false, fetch: true, attemptSynchronously: synchronousLoad)
    
    let maybeFullSize = postbox.mediaBox.cachedResourceRepresentation(fileReference.media.resource, representation: thumbnailSize ? CachedScaledVideoFirstFrameRepresentation(size: CGSize(width: 160.0, height: 160.0)) : CachedVideoFirstFrameRepresentation(), complete: false, fetch: false, attemptSynchronously: synchronousLoad)
    
    let signal = maybeFullSize
        |> take(1)
        |> mapToSignal { maybeData -> Signal<(Atomic<Data?>, Atomic<Data?>, Bool), NoError> in
            if maybeData.complete {
                let loadedData: Data?
                loadedData = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                return .single((Atomic(value: nil), Atomic(value: loadedData), true))
            } else {
                
                
                let decodedThumbnailData = fileReference.media.immediateThumbnailData.flatMap(decodeTinyThumbnail)
                let fetchedThumbnail: Signal<FetchResourceSourceType, NoError>
                if let smallestRepresentation = smallestImageRepresentation(fileReference.media.previewRepresentations) {
                    fetchedThumbnail = fetchedMediaResource(postbox: postbox, reference: fileReference.resourceReference(smallestRepresentation.resource), statsCategory: .image) |> `catch` { _ in return .complete() }
                } else {
                    fetchedThumbnail = .complete()
                }
                
                
                
                let mainThumbnail = Signal<(Atomic<Data?>, Bool), NoError> { subscriber in
                    if let decodedThumbnailData = decodedThumbnailData {
                        subscriber.putNext((Atomic(value: decodedThumbnailData), true))
                    }
                    
                    let fetchedDisposable = fetchedThumbnail.start()
                    var thumbnailDisposable: Disposable? = nil
                    if let smallestRepresentation = smallestImageRepresentation(fileReference.media.previewRepresentations) {
                        thumbnailDisposable = postbox.mediaBox.resourceData(smallestRepresentation.resource, attemptSynchronously: synchronousLoad).start(next: { next in
                            subscriber.putNext((Atomic(value: next.size == 0 ? decodedThumbnailData : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])), next.size == 0))
                        }, error: subscriber.putError, completed: subscriber.putCompletion)
                    } else {
                        subscriber.putNext((Atomic(value: nil), true))
                    }
                   
                    
                    return ActionDisposable {
                        fetchedDisposable.dispose()
                        thumbnailDisposable?.dispose()
                    }
                }
                
                let thumbnail = mainThumbnail
                
                let fullSizeData: Signal<(Atomic<Data?>, Bool), NoError>
                
                fullSizeData = fetchedFullSize
                    |> map { next -> (Atomic<Data?>, Bool) in
                        return (Atomic(value: next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])), next.complete)
                }
                
                
                return thumbnail
                    |> mapToSignal { thumbnailData in
                        let isThumb = thumbnailData.1
                        return fullSizeData
                            |> map { (fullSizeData, complete) in
                                if !isThumb && !complete {
                                    return (Atomic(value: nil), thumbnailData.0, complete)
                                }
                                return (complete ? Atomic(value: nil) : thumbnailData.0, fullSizeData, complete)
                        }
                }
            }
    }
    //            |> distinctUntilChanged(isEqual: { lhs, rhs in
    //                return true
    //            })
    
    return signal
    
    
//    let image = TelegramMediaImage(imageId: fileReference.media.id ?? MediaId(namespace: 0, id: 0), representations: fileReference.media.previewRepresentations, immediateThumbnailData: fileReference.media.immediateThumbnailData, reference: nil, partialReference: fileReference.media.partialReference)
//    let imageReference: ImageMediaReference
//    switch fileReference {
//    case let .message(message, _):
//        imageReference = ImageMediaReference.message(message: message, media: image)
//    case .savedGif:
//        imageReference = ImageMediaReference.savedGif(media: image)
//    case .standalone:
//        imageReference = ImageMediaReference.standalone(media: image)
//    case let .stickerPack(stickerPack, _):
//        imageReference = ImageMediaReference.stickerPack(stickerPack: stickerPack, media: image)
//    case let .webPage(webPage, _):
//        imageReference = ImageMediaReference.webPage(webPage: webPage, media: image)
//    }
//
//    return chatMessagePhotoDatas(postbox: postbox, imageReference: imageReference, autoFetchFullSize: true, synchronousLoad: synchronousLoad)
//
//    let fullSizeResource = fileReference.media.resource
//
//    let thumbnailResource = smallestImageRepresentation(fileReference.media.previewRepresentations)?.resource
//
//    let maybeFullSize = postbox.mediaBox.cachedResourceRepresentation(fullSizeResource, representation: thumbnailSize ? CachedScaledVideoFirstFrameRepresentation(size: CGSize(width: 160.0, height: 160.0)) : CachedVideoFirstFrameRepresentation(), complete: false, fetch: false, attemptSynchronously: synchronousLoad)
//    let fetchedFullSize = postbox.mediaBox.cachedResourceRepresentation(fullSizeResource, representation: thumbnailSize ? CachedScaledVideoFirstFrameRepresentation(size: CGSize(width: 160.0, height: 160.0)) : CachedVideoFirstFrameRepresentation(), complete: false, fetch: true, attemptSynchronously: synchronousLoad)
//
//    let signal = maybeFullSize
//        |> take(1)
//        |> mapToSignal { maybeData -> Signal<(Atomic<Data?>, (Atomic<Data>, String)?, Bool), NoError> in
//            if maybeData.complete {
//                let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
//
//                return .single((Atomic(value: nil), loadedData == nil ? nil : (Atomic(value: loadedData!), maybeData.path), true))
//            } else {
//                let thumbnail: Signal<Atomic<Data?>, NoError>
//                if onlyFullSize {
//                    thumbnail = .single(Atomic(value: nil))
//                } else if let decodedThumbnailData = fileReference.media.immediateThumbnailData.flatMap(decodeTinyThumbnail) {
//                    thumbnail = .single(Atomic(value: decodedThumbnailData))
//                } else if let thumbnailResource = thumbnailResource {
//                    thumbnail = Signal { subscriber in
//                        let fetchedDisposable = fetchedMediaResource(postbox: postbox, reference: fileReference.resourceReference(thumbnailResource), statsCategory: .video).start()
//                        let thumbnailDisposable = postbox.mediaBox.resourceData(thumbnailResource, attemptSynchronously: synchronousLoad).start(next: { next in
//                            subscriber.putNext(Atomic(value: next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])))
//                        }, error: subscriber.putError, completed: subscriber.putCompletion)
//
//                        return ActionDisposable {
//                            fetchedDisposable.dispose()
//                            thumbnailDisposable.dispose()
//                        }
//                    }
//                } else {
//                    thumbnail = .single(Atomic(value: nil))
//                }
//
//                let fullSizeDataAndPath = Signal<MediaResourceData, NoError> { subscriber in
//                    let dataDisposable = fetchedFullSize.start(next: { next in
//                        subscriber.putNext(next)
//                    }, completed: {
//                        subscriber.putCompletion()
//                    })
//                    //let fetchedDisposable = fetchedPartialVideoThumbnailData(postbox: postbox, fileReference: fileReference).start()
//                    return ActionDisposable {
//                        dataDisposable.dispose()
//                        //fetchedDisposable.dispose()
//                    }
//                } |> map { next -> ((Atomic<Data>, String)?, Bool) in
//                    let data = next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: .mappedIfSafe)
//                    return (data == nil ? nil : (Atomic(value: data!), next.path), next.complete)
//                }
//
//                return thumbnail
//                    |> mapToSignal { thumbnailData in
//                        return fullSizeDataAndPath
//                            |> map { (dataAndPath, complete) in
//                                return (thumbnailData, dataAndPath, complete)
//                        }
//                }
//            }
//        } |> filter({
//            if onlyFullSize {
//                return $0.1 != nil || $0.2
//            } else {
//                return true//$0.0 != nil || $0.1 != nil || $0.2
//            }
//        })
//
//    return signal
}



func chatMessageVideo(postbox: Postbox, fileReference: FileMediaReference, scale: CGFloat, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    return mediaGridMessageVideo(postbox: postbox, fileReference: fileReference, scale: scale, synchronousLoad: synchronousLoad)
}


private func chatSecretMessageVideoData(account: Account, fileReference: FileMediaReference, synchronousLoad: Bool = false) -> Signal<Atomic<Data?>, NoError> {
    if let smallestRepresentation = smallestImageRepresentation(fileReference.media.previewRepresentations) {
        let thumbnailResource = smallestRepresentation.resource
        
        let fetchedThumbnail = fetchedMediaResource(postbox: account.postbox, reference: fileReference.resourceReference(thumbnailResource), statsCategory: .video)
        
        let thumbnail = Signal<Atomic<Data?>, NoError> { subscriber in
            let fetchedDisposable = fetchedThumbnail.start()
            let thumbnailDisposable = account.postbox.mediaBox.resourceData(thumbnailResource, attemptSynchronously: synchronousLoad).start(next: { next in
                subscriber.putNext(Atomic(value: next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])))
            }, error: subscriber.putError, completed: subscriber.putCompletion)
            
            return ActionDisposable {
                fetchedDisposable.dispose()
                thumbnailDisposable.dispose()
            }
        }
        return thumbnail
    } else {
        return .single(Atomic(value: nil))
    }
}

func chatSecretMessageVideo(account: Account, fileReference: FileMediaReference, scale:CGFloat, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatSecretMessageVideoData(account: account, fileReference: fileReference, synchronousLoad: synchronousLoad)
    
    return signal |> map { thumbnailData in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale: scale, clear: true)
            if arguments.drawingSize.width.isLessThanOrEqualTo(0.0) || arguments.drawingSize.height.isLessThanOrEqualTo(0.0) {
                return context
            }
            
            let thumbnailData = thumbnailData.with {$0}
            
            let drawingRect = arguments.drawingRect
            let fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize).fitted(arguments.imageSize)
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
    
            var blurredImage: CGImage?
            
            if blurredImage == nil {
                if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                    let thumbnailSize = CGSize(width: image.width, height: image.height)
                    let thumbnailContextSize = thumbnailSize.aspectFilled(CGSize(width: 20.0, height: 20.0))
                    let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                    thumbnailContext.withContext { c in
                        c.interpolationQuality = .none
                        c.draw(image, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                    }
                    telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                    
                    let thumbnailContext2Size = thumbnailSize.aspectFitted(CGSize(width: 100.0, height: 100.0))
                    let thumbnailContext2 = DrawingContext(size: thumbnailContext2Size, scale: 1.0)
                    thumbnailContext2.withContext { c in
                        c.interpolationQuality = .none
                        if let image = thumbnailContext.generateImage() {
                            c.draw(image, in: CGRect(origin: CGPoint(), size: thumbnailContext2Size))
                        }
                    }
                    telegramFastBlur(Int32(thumbnailContext2Size.width), Int32(thumbnailContext2Size.height), Int32(thumbnailContext2.bytesPerRow), thumbnailContext2.bytes)
                    
                    blurredImage = thumbnailContext2.generateImage()
                }
            }
            
            context.withContext { c in
                c.setBlendMode(.copy)
                if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                    //c.setFillColor(NSColor(white: 0.0, alpha: 0.4).cgColor)
                    c.fill(arguments.drawingRect)
                }
                
                c.setBlendMode(.copy)
                if let cgImage = blurredImage {
                    c.interpolationQuality = .low
                    c.draw(cgImage, in: fittedRect)
                }
                
                if !arguments.insets.left.isEqual(to: 0.0) {
                    c.clear(CGRect(origin: CGPoint(), size: CGSize(width: arguments.insets.left, height: context.size.height)))
                }
                if !arguments.insets.right.isEqual(to: 0.0) {
                    c.clear(CGRect(origin: CGPoint(x: context.size.width - arguments.insets.right, y: 0.0), size: CGSize(width: arguments.insets.right, height: context.size.height)))
                }
            }
            
            addCorners(context, arguments: arguments, scale: scale)
            
            return context
        }
    }
}



private enum Corner: Hashable {
    case TopLeft(Int), TopRight(Int), BottomLeft(Int), BottomRight(Int)
    
    var hashValue: Int {
        switch self {
        case let .TopLeft(radius):
            return radius | (1 << 24)
        case let .TopRight(radius):
            return radius | (2 << 24)
        case let .BottomLeft(radius):
            return radius | (3 << 24)
        case let .BottomRight(radius):
            return radius | (2 << 24)
        }
    }
    
    var radius: Int {
        switch self {
        case let .TopLeft(radius):
            return radius
        case let .TopRight(radius):
            return radius
        case let .BottomLeft(radius):
            return radius
        case let .BottomRight(radius):
            return radius
        }
    }
}



private enum Tail: Hashable {
    case BottomLeft(Int)
    case BottomRight(Int)
    
    var hashValue: Int {
        switch self {
        case let .BottomLeft(radius):
            return radius | (1 << 24)
        case let .BottomRight(radius):
            return radius | (2 << 24)
        }
    }
    
    var radius: Int {
        switch self {
        case let .BottomLeft(radius):
            return radius
        case let .BottomRight(radius):
            return radius
        }
    }
}

private func ==(lhs: Tail, rhs: Tail) -> Bool {
    switch lhs {
    case let .BottomLeft(lhsRadius):
        switch rhs {
        case let .BottomLeft(rhsRadius) where rhsRadius == lhsRadius:
            return true
        default:
            return false
        }
    case let .BottomRight(lhsRadius):
        switch rhs {
        case let .BottomRight(rhsRadius) where rhsRadius == lhsRadius:
            return true
        default:
            return false
        }
    }
}

private var cachedCorners: [CGFloat: [Corner: DrawingContext]] = [:]
private let cachedCornersLock = SwiftSignalKitMac.Lock()
private var cachedTails: [Tail: DrawingContext] = [:]
private let cachedTailsLock = SwiftSignalKitMac.Lock()


private func cornerContext(_ corner: Corner, scale:CGFloat) -> DrawingContext {
    var cached: DrawingContext?
    cachedCornersLock.locked {
        cached = cachedCorners[scale]?[corner]
    }
    
    if let cached = cached {
        return cached
    } else {
        let context = DrawingContext(size: CGSize(width: CGFloat(corner.radius), height: CGFloat(corner.radius)), scale: scale, clear: true)
        
        context.withContext { c in
            c.setBlendMode(.copy)
            c.setFillColor(NSColor.black.cgColor)
            let rect: CGRect
            switch corner {
            case let .TopLeft(radius):
                rect = CGRect(origin: CGPoint(x: 0.0, y: -CGFloat(radius)), size: CGSize(width: CGFloat(radius << 1), height: CGFloat(radius << 1)))
            case let .TopRight(radius):
                rect = CGRect(origin: CGPoint(x: -CGFloat(radius), y: -CGFloat(radius)), size: CGSize(width: CGFloat(radius << 1), height: CGFloat(radius << 1)))
            case let .BottomLeft(radius):
                rect = CGRect(origin: CGPoint(), size: CGSize(width: CGFloat(radius << 1), height: CGFloat(radius << 1)))
            case let .BottomRight(radius):
               rect = CGRect(origin: CGPoint(x: -CGFloat(radius), y: 0.0), size: CGSize(width: CGFloat(radius << 1), height: CGFloat(radius << 1)))
            }
            c.fillEllipse(in: rect)
        }
        
        cachedCornersLock.locked {
            if cachedCorners[scale] == nil {
                cachedCorners[scale] = [:]
            }
            cachedCorners[scale]?[corner] = context
        }
        return context
    }
}

private func tailContext(_ tail: Tail, scale:CGFloat) -> DrawingContext {
    var cached: DrawingContext?
    cachedTailsLock.locked {
        cached = cachedTails[tail]
    }
    
    if let cached = cached {
        return cached
    } else {
        let context = DrawingContext(size: CGSize(width: CGFloat(tail.radius) + 3.0, height: CGFloat(tail.radius)), scale:scale, clear: true)
        
        context.withContext { c in
            c.setBlendMode(.copy)
            c.setFillColor(NSColor.black.cgColor)
            let rect: CGRect
            switch tail {
            case let .BottomLeft(radius):
                rect = CGRect(origin: CGPoint(x: 3.0, y: -CGFloat(radius)), size: CGSize(width: CGFloat(radius << 1), height: CGFloat(radius << 1)))
                
                c.move(to: CGPoint(x: 3.0, y: 0.0))
                c.addLine(to: CGPoint(x: 3.0, y: 8.7))
                c.addLine(to: CGPoint(x: 2.0, y: 11.7))
                c.addLine(to: CGPoint(x: 1.5, y: 12.7))
                c.addLine(to: CGPoint(x: 0.8, y: 13.7))
                c.addLine(to: CGPoint(x: 0.2, y: 14.4))
                c.addLine(to: CGPoint(x: 3.5, y: 13.8))
                c.addLine(to: CGPoint(x: 5.0, y: 13.2))
                c.addLine(to: CGPoint(x: 3.0 + CGFloat(radius) - 9.5, y: 11.5))
                c.closePath()
                c.fillPath()
            case let .BottomRight(radius):
                rect = CGRect(origin: CGPoint(x: -CGFloat(radius) + 3.0, y: -CGFloat(radius)), size: CGSize(width: CGFloat(radius << 1), height: CGFloat(radius << 1)))
                
                /*CGContextMoveToPoint(c, 3.0, 0.0)
                 CGContextAddLineToPoint(c, 3.0, 8.7)
                 CGContextAddLineToPoint(c, 2.0, 11.7)
                 CGContextAddLineToPoint(c, 1.5, 12.7)
                 CGContextAddLineToPoint(c, 0.8, 13.7)
                 CGContextAddLineToPoint(c, 0.2, 14.4)
                 CGContextAddLineToPoint(c, 3.5, 13.8)
                 CGContextAddLineToPoint(c, 5.0, 13.2)
                 CGContextAddLineToPoint(c, 3.0 + CGFloat(radius) - 9.5, 11.5)
                 CGContextClosePath(c)
                 CGContextFillPath(c)*/
            }
            c.fillEllipse(in: rect)
        }
        
        cachedCornersLock.locked {
            cachedTails[tail] = context
        }
        return context
    }
}



private func addCorners(_ context: DrawingContext, arguments: TransformImageArguments, scale:CGFloat) {
    let corners = arguments.corners
    let drawingRect = arguments.drawingRect
    
    if case let .Corner(radius) = corners.topLeft, radius > CGFloat.ulpOfOne {
        let corner = cornerContext(.TopLeft(Int(radius)), scale:scale)
        context.blt(corner, at: CGPoint(x: drawingRect.minX, y: drawingRect.minY))
    }
    
    if case let .Corner(radius) = corners.topRight, radius > CGFloat.ulpOfOne {
        let corner = cornerContext(.TopRight(Int(radius)), scale:scale)
        context.blt(corner, at: CGPoint(x: drawingRect.maxX - radius, y: drawingRect.minY))
    }
    
    switch corners.bottomLeft {
    case let .Corner(radius):
        if radius > CGFloat.ulpOfOne {
            let corner = cornerContext(.BottomLeft(Int(radius)), scale:scale)
            context.blt(corner, at: CGPoint(x: drawingRect.minX, y: drawingRect.maxY - radius))
        }
    case let .Tail(radius):
        if radius > CGFloat.ulpOfOne {
            let tail = tailContext(.BottomLeft(Int(radius)), scale:scale)
            let color = context.colorAt(CGPoint(x: drawingRect.minX, y: drawingRect.maxY - 1.0))
            context.withContext { c in
                c.setFillColor(color.cgColor)
                c.fill(CGRect(x: 0.0, y: drawingRect.maxY - 6.0, width: 3.0, height: 6.0))
            }
            context.blt(tail, at: CGPoint(x: drawingRect.minX - 3.0, y: drawingRect.maxY - radius))
        }
        
    }
    
    switch corners.bottomRight {
    case let .Corner(radius):
        if radius > CGFloat.ulpOfOne {
            let corner = cornerContext(.BottomRight(Int(radius)), scale:scale)
            context.blt(corner, at: CGPoint(x: drawingRect.maxX - radius, y: drawingRect.maxY - radius))
        }
    case let .Tail(radius):
        if radius > CGFloat.ulpOfOne {
            let tail = tailContext(.BottomRight(Int(radius)), scale:scale)
            context.blt(tail, at: CGPoint(x: drawingRect.maxX - radius - 3.0, y: drawingRect.maxY - radius))
        }
    }
}


func mediaGridMessagePhoto(account: Account, imageReference: ImageMediaReference, scale:CGFloat) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessagePhotoDatas(postbox: account.postbox, imageReference: imageReference, fullRepresentationSize: CGSize(width: 127.0, height: 127.0), autoFetchFullSize: true)
    
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            assertNotOnMainThread()
            let context = DrawingContext(size: arguments.drawingSize, scale:scale, clear: true)
            
            let thumbnailData = thumbnailData.with {$0}
            let fullSizeData = fullSizeData.with {$0}
            
            let drawingRect = arguments.drawingRect
            let fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize).fitted(arguments.imageSize)
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options.setValue(max(fittedSize.width * context.scale, fittedSize.height * context.scale) as NSNumber, forKey: kCGImageSourceThumbnailMaxPixelSize as String)
                    options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: CGImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlurMore(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                blurredThumbnailImage = thumbnailContext.generateImage()
            }
            
            context.withContext(isHighQuality: fullSizeImage != nil, { c in
                c.setBlendMode(.copy)
                c.setFillColor(theme.colors.grayBackground.cgColor)
                if arguments.boundingSize != arguments.imageSize {
                   c.fill(arguments.drawingRect)
                }
                
                c.setBlendMode(.copy)
                if let blurredThumbnailImage = blurredThumbnailImage {
                    c.interpolationQuality = .low
                    c.draw(blurredThumbnailImage, in: fittedRect)
                    c.setBlendMode(.normal)
                }
                
                if let fullSizeImage = fullSizeImage {
                    c.interpolationQuality = .medium
                    c.draw(fullSizeImage, in: fittedRect)
                }
                
                if arguments.boundingSize == arguments.imageSize && fullSizeImage == nil && blurredThumbnailImage == nil {
                    c.setBlendMode(.normal)
                    c.fill(arguments.drawingRect)
                }
            })
            
            addCorners(context, arguments: arguments, scale:scale)
            
            return context
        }
    }
}



func chatMessageVideoThumbnail(account: Account, fileReference: FileMediaReference, scale: CGFloat, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessageVideoDatas(postbox: account.postbox, fileReference: fileReference, thumbnailSize: true, synchronousLoad: synchronousLoad)
    
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale: scale, clear: true)
            
            let thumbnailData = thumbnailData.with {$0}
            
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData.with({$0}) {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: CGImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                blurredThumbnailImage = thumbnailContext.generateImage()
            }
            
            context.withFlippedContext(isHighQuality: fullSizeImage != nil, { c in
                c.setBlendMode(.copy)
                if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                    //c.setFillColor(NSColor(white: 0.0, alpha: 0.4).cgColor)
                    c.fill(arguments.drawingRect)
                }
                
                c.setBlendMode(.copy)
                if let cgImage = blurredThumbnailImage {
                    c.interpolationQuality = .low
                    c.draw(cgImage, in: fittedRect)
                    c.setBlendMode(.normal)
                }
                
                if let fullSizeImage = fullSizeImage {
                    c.interpolationQuality = .medium
                    c.draw(fullSizeImage, in: fittedRect)
                }
            })
            
            addCorners(context, arguments: arguments, scale: scale)
            
            return context
        }
    }
}


func mediaGridMessageVideo(postbox: Postbox, fileReference: FileMediaReference, scale: CGFloat, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessageVideoDatas(postbox: postbox, fileReference: fileReference, synchronousLoad: synchronousLoad)
    
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale: scale, clear: true)
            
            let thumbnailData = thumbnailData.with {$0}
            
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize).fitted(arguments.imageSize)
            if fittedSize.width < drawingRect.size.width && fittedSize.width >= drawingRect.size.width - 2.0 {
                fittedSize.width = drawingRect.size.width
            }
            if fittedSize.height < drawingRect.size.height && fittedSize.height >= drawingRect.size.height - 2.0 {
                fittedSize.height = drawingRect.size.height
            }
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData.with({$0}) {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if fullSizeImage == nil, let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: CGImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlurMore(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)

                blurredThumbnailImage = thumbnailContext.generateImage()
            }
            
            context.withFlippedContext(isHighQuality: fullSizeComplete, { c in
                c.setBlendMode(.copy)
                if arguments.boundingSize != arguments.imageSize {
                    switch arguments.resizeMode {
                    case .blurBackground:
                        let blurSourceImage = thumbnailImage ?? fullSizeImage
                        
                        if let fullSizeImage = blurSourceImage {
                            let thumbnailSize = CGSize(width: fullSizeImage.width, height: fullSizeImage.height)
                            let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 74.0, height: 74.0))
                            let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                            thumbnailContext.withFlippedContext { c in
                                c.interpolationQuality = .none
                                c.draw(fullSizeImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                            }
                         //   telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                            telegramFastBlurMore(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                            
                            if let blurredImage = thumbnailContext.generateImage() {
                                let filledSize = thumbnailSize.aspectFilled(arguments.drawingRect.size)
                                c.interpolationQuality = .medium
                                c.draw(blurredImage, in: CGRect(origin: CGPoint(x: arguments.drawingRect.minX + (arguments.drawingRect.width - filledSize.width) / 2.0, y: arguments.drawingRect.minY + (arguments.drawingRect.height - filledSize.height) / 2.0), size: filledSize))
                                c.setBlendMode(.normal)
                                c.setFillColor(theme.colors.background.withAlphaComponent(0.5).cgColor)
                                c.fill(arguments.drawingRect)
                                c.setBlendMode(.copy)
                            }
                        } else {
                            c.fill(arguments.drawingRect)
                        }
                    case let .fill(color):
                        c.setFillColor(color.cgColor)
                        c.fill(arguments.drawingRect)
                    case .fillTransparent:
                        c.setFillColor(theme.colors.transparentBackground.cgColor)
                        c.fill(arguments.drawingRect)
                    case .none:
                        break
                    case .imageColor:
                        break
                    }
                }
                
                c.setBlendMode(.copy)
                if let cgImage = blurredThumbnailImage {
                    c.interpolationQuality = .low
                    c.draw(cgImage, in: fittedRect)
                    c.setBlendMode(.normal)
                }
                
                if let fullSizeImage = fullSizeImage {
                    c.interpolationQuality = .medium
                    c.draw(fullSizeImage, in: fittedRect)
                }
            })
            
            addCorners(context, arguments: arguments, scale: scale)
            
            return context
        }
    }
}


private func imageFromAJpeg(data: Data) -> (CGImage, CGImage)? {
    if let (colorData, alphaData) = data.withUnsafeBytes({ (bytes: UnsafePointer<UInt8>) -> (Data, Data)? in
        var colorSize: Int32 = 0
        memcpy(&colorSize, bytes, 4)
        if colorSize < 0 || Int(colorSize) > data.count - 8 {
            return nil
        }
        var alphaSize: Int32 = 0
        memcpy(&alphaSize, bytes.advanced(by: 4 + Int(colorSize)), 4)
        if alphaSize < 0 || Int(alphaSize) > data.count - Int(colorSize) - 8 {
            return nil
        }
        //let colorData = Data(bytesNoCopy: UnsafeMutablePointer(mutating: bytes).advanced(by: 4), count: Int(colorSize), deallocator: .none)
        //let alphaData = Data(bytesNoCopy: UnsafeMutablePointer(mutating: bytes).advanced(by: 4 + Int(colorSize) + 4), count: Int(alphaSize), deallocator: .none)
        let colorData = data.subdata(in: 4 ..< (4 + Int(colorSize)))
        let alphaData = data.subdata(in: (4 + Int(colorSize) + 4) ..< (4 + Int(colorSize) + 4 + Int(alphaSize)))
        return (colorData, alphaData)
    }) {
        
        let sourceColor:CGImageSource? = CGImageSourceCreateWithData(colorData as CFData, nil);
        let sourceAlpha:CGImageSource? = CGImageSourceCreateWithData(alphaData as CFData, nil);
        
         if let sourceColor = sourceColor, let sourceAlpha = sourceAlpha {
            
            let colorImage =  CGImageSourceCreateImageAtIndex(sourceColor, 0, nil);
            let alphaImage =  CGImageSourceCreateImageAtIndex(sourceAlpha, 0, nil);
            if let colorImage = colorImage, let alphaImage = alphaImage {
                return (colorImage, alphaImage)
            }
        }
    }
    return nil
}


public func putToTemp(image:NSImage, compress: Bool = true) -> Signal<String, NoError> {
    return Signal { (subscriber) in

        
     //   let data:Data? = image.tiffRepresentation(using: .jpeg, factor: compress ? 0.83 : 1)
        if let data = image.tiffRepresentation(using: compress ? .jpeg : .none, factor: compress ? 0.83 : 1.0) {
            let path = NSTemporaryDirectory() + "tg_image_\(arc4random()).jpeg"
            if compress {
                let imageRep = NSBitmapImageRep(data: data)
                try? imageRep?.representation(using: .jpeg, properties: [:])?.write(to: URL(fileURLWithPath: path))
            } else {
               // try? data.write(to: URL(fileURLWithPath: path))
                
                
                let options = NSMutableDictionary()
                
                let mutableData: CFMutableData = NSMutableData() as CFMutableData
                
                if let colorDestination = CGImageDestinationCreateWithData(mutableData, kUTTypeJPEG, 1, nil) {
                    CGImageDestinationAddImage(colorDestination, image.cgImage(forProposedRect: nil, context: nil, hints: nil)!, options as CFDictionary)
                    if CGImageDestinationFinalize(colorDestination) {
                        try? (mutableData as Data).write(to: URL(fileURLWithPath: path))
                    }
                }

            }
           

            

            subscriber.putNext(path)
        }
        
        

        
        subscriber.putCompletion()
        
        return EmptyDisposable
    } |> runOn(resourcesQueue)
}


public func filethumb(with url:URL, account:Account, scale:CGFloat) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    return Signal<Data?, NoError> { (subscriber) in
        
        let data = try? Data(contentsOf: url)
        
        subscriber.putNext(data)
        subscriber.putCompletion()
        
        return EmptyDisposable
    } |> map({ (data) in
        
        return { arguments in
            
            let context = DrawingContext(size: arguments.drawingSize, scale:scale, clear: true)
            
            let drawingRect = arguments.drawingRect
            let fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize).fitted(arguments.imageSize)
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)

            var thumb: CGImage?
            if let data = data {
                let options = NSMutableDictionary()
                options.setValue(max(fittedSize.width * context.scale, fittedSize.height * context.scale) as NSNumber, forKey: kCGImageSourceThumbnailMaxPixelSize as String)
                options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)
                if let imageSource = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                    thumb = image
                }
            }
            
            if let thumb = thumb {
                context.withContext({ (ctx) in
                    ctx.setBlendMode(.copy)
                    ctx.interpolationQuality = .medium
                    ctx.draw(thumb, in: fittedRect)
                })
            }
            addCorners(context, arguments: arguments, scale:scale)
            
            return context
        }
    })
    
}



func chatSecretPhoto(account: Account, imageReference: ImageMediaReference, scale:CGFloat, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessagePhotoDatas(postbox: account.postbox, imageReference: imageReference, synchronousLoad: synchronousLoad)
    
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale: scale, clear: true)
            
            let fullSizeData = fullSizeData.with {$0}
            let thumbnailData = thumbnailData.with {$0}
            
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var blurredImage: CGImage?
            
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        let thumbnailSize = CGSize(width: image.width, height: image.height)
                        let thumbnailContextSize = thumbnailSize.aspectFilled(CGSize(width: 20.0, height: 20.0))
                        let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                        thumbnailContext.withContext { c in
                            c.interpolationQuality = .none
                            c.draw(image, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                        }
                        telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                        
                        let thumbnailContext2Size = thumbnailSize.aspectFitted(CGSize(width: 100.0, height: 100.0))
                        let thumbnailContext2 = DrawingContext(size: thumbnailContext2Size, scale: 1.0)
                        thumbnailContext2.withContext { c in
                            c.interpolationQuality = .none
                            if let image = thumbnailContext.generateImage() {
                                c.draw(image, in: CGRect(origin: CGPoint(), size: thumbnailContext2Size))
                            }
                        }
                        telegramFastBlur(Int32(thumbnailContext2Size.width), Int32(thumbnailContext2Size.height), Int32(thumbnailContext2.bytesPerRow), thumbnailContext2.bytes)
                        
                        blurredImage = thumbnailContext2.generateImage()
                    }
                }/* else {
                 let imageSource = CGImageSourceCreateIncremental(nil)
                 CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                 
                 let options = NSMutableDictionary()
                 options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                 if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                 fullSizeImage = image
                 }
                 }*/
            }
            
            if blurredImage == nil {
                if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                    let thumbnailSize = CGSize(width: image.width, height: image.height)
                    let thumbnailContextSize = thumbnailSize.aspectFilled(CGSize(width: 20.0, height: 20.0))
                    let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                    thumbnailContext.withFlippedContext { c in
                        c.interpolationQuality = .none
                        c.draw(image, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                    }
                    telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                    
                    let thumbnailContext2Size = thumbnailSize.aspectFitted(CGSize(width: 100.0, height: 100.0))
                    let thumbnailContext2 = DrawingContext(size: thumbnailContext2Size, scale: 1.0)
                    thumbnailContext2.withFlippedContext { c in
                        c.interpolationQuality = .none
                        if let image = thumbnailContext.generateImage() {
                            c.draw(image, in: CGRect(origin: CGPoint(), size: thumbnailContext2Size))
                        }
                    }
                    telegramFastBlur(Int32(thumbnailContext2Size.width), Int32(thumbnailContext2Size.height), Int32(thumbnailContext2.bytesPerRow), thumbnailContext2.bytes)
                    
                    blurredImage = thumbnailContext2.generateImage()
                }
            }
            
            context.withContext { c in
                c.setBlendMode(.copy)
                if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                    //c.setFillColor(NSColor(white: 0.0, alpha: 0.4).cgColor)
                    c.fill(arguments.drawingRect)
                }
                
                c.setBlendMode(.copy)
                if let cgImage = blurredImage {
                    c.interpolationQuality = .low
                    c.draw(cgImage, in: fittedRect)
                }
                
                if !arguments.insets.left.isEqual(to: 0.0) {
                    c.clear(CGRect(origin: CGPoint(), size: CGSize(width: arguments.insets.left, height: context.size.height)))
                }
                if !arguments.insets.right.isEqual(to: 0.0) {
                    c.clear(CGRect(origin: CGPoint(x: context.size.width - arguments.insets.right, y: 0.0), size: CGSize(width: arguments.insets.right, height: context.size.height)))
                }
            }
            
            addCorners(context, arguments: arguments, scale:scale)
            
            return context
        }
    }
}


func chatMessageImageFile(account: Account, fileReference: FileMediaReference, progressive: Bool = false, scale: CGFloat, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessageFileDatas(account: account, fileReference: fileReference, progressive: progressive, justThumbail: true, synchronousLoad: synchronousLoad)
    
    return signal |> map { (thumbnailData, fullSizeDataAndPath, fullSizeComplete) in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale: scale, clear: true)
            
            let drawingRect = arguments.drawingRect
            let fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize)//.fitted(arguments.imageSize)
            let fittedRect = CGRect(origin: CGPoint(x: floorToScreenPixels(scaleFactor: System.backingScale, drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0), y: floorToScreenPixels(scaleFactor: System.backingScale, drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0)), size: fittedSize)
            
            
            let thumbnailData = thumbnailData.with {$0}
            
            var fullSizeImage: CGImage?

            if let path = fullSizeDataAndPath {
                if fullSizeComplete {
                     if let fullSizeData = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                        let options = NSMutableDictionary()
                        options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)
                        options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailWithTransform as String)
                        
                        //   options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                        if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, options) {
                            if let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options) {
                                fullSizeImage = image
                            } else if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options) {
                                fullSizeImage = image
                            }
                        }
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: CGImage?
            if let thumbnailImage = thumbnailImage, fullSizeImage == nil {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                blurredThumbnailImage = thumbnailContext.generateImage()
            }
            
            context.withFlippedContext(isHighQuality: fullSizeImage != nil, { c in
                //c.setBlendMode(.copy)
                if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                    c.setFillColor(theme.colors.transparentBackground.cgColor)
                    c.fill(arguments.drawingRect)
                }
                
              //  c.setBlendMode(.copy)
                if let cgImage = blurredThumbnailImage {
                    c.interpolationQuality = .low
                    c.draw(cgImage, in: fittedRect)
                    c.setBlendMode(.normal)
                }
                
                if let fullSizeImage = fullSizeImage {
                    c.interpolationQuality = .medium
                    c.setFillColor(theme.colors.transparentBackground.cgColor)
                    c.fill(fittedRect)
                    c.draw(fullSizeImage, in: fittedRect)
                }
            })
            
            addCorners(context, arguments: arguments, scale: scale)
            
            return context
        }
    }
}


private func chatMessagePhotoThumbnailDatas(account: Account, imageReference: ImageMediaReference, synchronousLoad: Bool = false, secureIdAccessContext: SecureIdAccessContext? = nil) -> Signal<(Atomic<Data?>, Atomic<Data?>, Bool), NoError> {
    let fullRepresentationSize: CGSize = CGSize(width: 1280.0, height: 1280.0)
    if let smallestRepresentation = smallestImageRepresentation(imageReference.media.representations), let largestRepresentation = imageReference.media.representationForDisplayAtSize(fullRepresentationSize) {
        
        let size = CGSize(width: 160.0, height: 160.0)
        let maybeFullSize: Signal<MediaResourceData, NoError>
            
        if largestRepresentation.resource is EncryptedMediaResource {
            maybeFullSize = account.postbox.mediaBox.resourceData(largestRepresentation.resource, attemptSynchronously: synchronousLoad)
        } else {
            maybeFullSize = account.postbox.mediaBox.cachedResourceRepresentation(largestRepresentation.resource, representation: CachedScaledImageRepresentation(size: size), complete: false, attemptSynchronously: synchronousLoad)
        }
        
        //take(1)
        let signal = maybeFullSize |> mapToSignal { maybeData -> Signal<(Atomic<Data?>, Atomic<Data?>, Bool), NoError> in
            if maybeData.complete {
                if largestRepresentation.resource is EncryptedMediaResource, let secureIdAccessContext = secureIdAccessContext {
                    let loadedData: Data? = decryptedResourceData(data: maybeData, resource: largestRepresentation.resource, params: secureIdAccessContext)
                    return .single((Atomic(value: nil), Atomic(value: loadedData), true))
                } else {
                    let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                    return .single((Atomic(value: nil), Atomic(value: loadedData), true))
                }
                
            } else {
                
                let fetchedThumbnail = fetchedMediaResource(postbox: account.postbox, reference: imageReference.resourceReference(smallestRepresentation.resource), statsCategory: .image)//account.postbox.mediaBox.fetchedResource(smallestRepresentation.resource, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
                
                let thumbnail = Signal<Atomic<Data?>, NoError> { subscriber in
                    let fetchedDisposable = fetchedThumbnail.start()
                    let thumbnailDisposable = account.postbox.mediaBox.resourceData(smallestRepresentation.resource, attemptSynchronously: synchronousLoad).start(next: { next in
                        subscriber.putNext(Atomic(value: next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])))
                    }, error: subscriber.putError, completed: subscriber.putCompletion)
                    
                    return ActionDisposable {
                        fetchedDisposable.dispose()
                        thumbnailDisposable.dispose()
                    }
                }
                
                let fullSizeData: Signal<(Atomic<Data?>, Bool), NoError> = maybeFullSize
                    |> map { next -> (Atomic<Data?>, Bool) in
                        return (Atomic(value: next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])), next.complete)
                }
                
                
                return thumbnail |> mapToSignal { thumbnailData in
                    return fullSizeData |> map { (fullSizeData, complete) in
                        return (thumbnailData, fullSizeData, complete)
                    }
                }
            }
            } |> filter({ $0.0.with {$0} != nil || $0.1.with {$0} != nil })
        
        return signal
    } else {
        return .never()
    }
}

func chatMessagePhotoThumbnail(account: Account,  imageReference: ImageMediaReference, scale: CGFloat = System.backingScale, synchronousLoad: Bool = false, secureIdAccessContext: SecureIdAccessContext? = nil) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatMessagePhotoThumbnailDatas(account: account, imageReference: imageReference, synchronousLoad: synchronousLoad, secureIdAccessContext: secureIdAccessContext)
    
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale: scale, clear: true)
            
            let fullSizeData = fullSizeData.with {$0}
            let thumbnailData = thumbnailData.with {$0}
            
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    /*let options = NSMutableDictionary()
                     options.setValue(max(fittedSize.width * context.scale, fittedSize.height * context.scale) as NSNumber, forKey: kCGImageSourceThumbnailMaxPixelSize as String)
                     options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)
                     if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                     fullSizeImage = image
                     }*/
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: CGImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                blurredThumbnailImage = thumbnailContext.generateImage()
            }
            
            context.withFlippedContext(isHighQuality: fullSizeImage != nil, { c in
                c.setBlendMode(.copy)
                if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                    //c.setFillColor(NSColor(white: 0.0, alpha: 0.4).cgColor)
                    c.fill(arguments.drawingRect)
                }
                
                c.setBlendMode(.copy)
                if let cgImage = blurredThumbnailImage {
                    c.interpolationQuality = .low
                    c.draw(cgImage, in: fittedRect)
                    c.setBlendMode(.normal)
                }
                
                if let fullSizeImage = fullSizeImage {
                    c.interpolationQuality = .medium
                    c.draw(fullSizeImage, in: fittedRect)
                }
            })
            
            addCorners(context, arguments: arguments, scale: scale)
            
            return context
        }
    }
}

private func builtinWallpaperData() -> Signal<CGImage, NoError> {
    return Signal { subscriber in
        if let filePath = Bundle.main.path(forResource: "builtin-wallpaper-0", ofType: "jpg"), let image = NSImage(contentsOfFile: filePath) {
            subscriber.putNext(image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        }
        subscriber.putCompletion()
        
        return EmptyDisposable
        } |> runOn(Queue.concurrentDefaultQueue())
}

func settingsBuiltinWallpaperImage(account: Account, scale: CGFloat = 2.0) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    return builtinWallpaperData() |> map { fullSizeImage in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale: scale, clear: true)
            
            let drawingRect = arguments.drawingRect
            var fittedSize = fullSizeImage.size.aspectFilled(drawingRect.size)
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            context.withFlippedContext { c in
                c.setBlendMode(.copy)
                c.interpolationQuality = .medium
                c.draw(fullSizeImage, in: fittedRect)
            }
            
            addCorners(context, arguments: arguments, scale: scale)
            
            return context
        }
    }
}

private func chatWallpaperDatas(account: Account, representations: [TelegramMediaImageRepresentation], autoFetchFullSize: Bool = false, isBlurred: Bool = false, synchronousLoad: Bool = false) -> Signal<(Atomic<Data?>, Atomic<Data?>, Bool), NoError> {
    if let smallestRepresentation = smallestImageRepresentation(representations), let largestRepresentation = largestImageRepresentation(representations) {
        let maybeFullSize: Signal<MediaResourceData, NoError>
        if isBlurred {
            maybeFullSize = account.postbox.mediaBox.cachedResourceRepresentation(largestRepresentation.resource, representation: CachedBlurredWallpaperRepresentation(), complete: false, attemptSynchronously: synchronousLoad)
        } else {
            maybeFullSize = account.postbox.mediaBox.resourceData(largestRepresentation.resource, attemptSynchronously: synchronousLoad)
        }
        
        
        let signal = maybeFullSize |> take(1) |> mapToSignal { maybeData -> Signal<(Atomic<Data?>, Atomic<Data?>, Bool), NoError> in
            if maybeData.complete {
                let loadedData: Data? = try? Data(contentsOf: URL(fileURLWithPath: maybeData.path), options: [])
                return .single((Atomic(value: nil), Atomic(value: loadedData), true))
            } else {
                let fetchedThumbnail = fetchedMediaResource(postbox: account.postbox, reference: MediaResourceReference.wallpaper(resource: smallestRepresentation.resource), statsCategory: .image) //account.postbox.mediaBox.fetchedResource(smallestRepresentation.resource, tag: TelegramMediaResourceFetchTag(statsCategory: .image))
                let fetchedFullSize = fetchedMediaResource(postbox: account.postbox, reference: MediaResourceReference.wallpaper(resource: largestRepresentation.resource), statsCategory: .image)
                
                let thumbnail = Signal<Atomic<Data?>, NoError> { subscriber in
                    let fetchedDisposable = fetchedThumbnail.start()
                    let thumbnailDisposable = account.postbox.mediaBox.resourceData(smallestRepresentation.resource, attemptSynchronously: synchronousLoad).start(next: { next in
                        subscriber.putNext(Atomic(value: next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])))
                    }, error: subscriber.putError, completed: subscriber.putCompletion)
                    
                    return ActionDisposable {
                        fetchedDisposable.dispose()
                        thumbnailDisposable.dispose()
                    }
                }
                
                let fullSizeData: Signal<(Atomic<Data?>, Bool), NoError>
                
                if autoFetchFullSize {
                    fullSizeData = Signal<(Atomic<Data?>, Bool), NoError> { subscriber in
                        let fetchedFullSizeDisposable = fetchedFullSize.start()
                        
                        let fetchData: Signal<MediaResourceData, NoError>
                        if isBlurred {
                            fetchData =  account.postbox.mediaBox.cachedResourceRepresentation(largestRepresentation.resource, representation: CachedBlurredWallpaperRepresentation(), complete: true, attemptSynchronously: synchronousLoad)
                        } else {
                            fetchData = account.postbox.mediaBox.resourceData(largestRepresentation.resource, attemptSynchronously: synchronousLoad)
                        }
                        
                        let fullSizeDisposable = fetchData.start(next: { next in
                            subscriber.putNext((Atomic(value: next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])), next.complete))
                        }, error: subscriber.putError, completed: subscriber.putCompletion)
                        
                        return ActionDisposable {
                            fetchedFullSizeDisposable.dispose()
                            fullSizeDisposable.dispose()
                        }
                    }
                } else {
                    fullSizeData = account.postbox.mediaBox.resourceData(largestRepresentation.resource)
                        |> map { next -> (Atomic<Data?>, Bool) in
                            return (Atomic(value: next.size == 0 ? nil : try? Data(contentsOf: URL(fileURLWithPath: next.path), options: [])), next.complete)
                    }
                }
                
                
                return thumbnail |> mapToSignal { thumbnailData in
                    return fullSizeData |> map { (fullSizeData, complete) in
                        return (thumbnailData, fullSizeData, complete)
                    }
                }
            }
            } |> filter({ $0.0.with {$0} != nil || $0.1.with {$0} != nil })
        
        return signal
    } else {
        return .never()
    }
}

enum PatternWallpaperDrawMode {
    case thumbnail
    case fastScreen
    case screen
}


func chatWallpaper(account: Account, representations: [TelegramMediaImageRepresentation], mode: PatternWallpaperDrawMode, autoFetchFullSize: Bool = false, scale: CGFloat = 2.0, isBlurred: Bool = false, synchronousLoad: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    let signal = chatWallpaperDatas(account: account, representations: representations, autoFetchFullSize: autoFetchFullSize, isBlurred: isBlurred, synchronousLoad: synchronousLoad)
    
    
    var prominent = false
    if case .thumbnail = mode {
        prominent = false
    }

    
    return signal |> map { (thumbnailData, fullSizeData, fullSizeComplete) in
        return { arguments in
            let context = DrawingContext(size: arguments.drawingSize, scale: scale, clear: true)
            
            let fullSizeData = fullSizeData.with {$0}
            let thumbnailData = thumbnailData.with {$0}
            
            
            let drawingRect = arguments.drawingRect
            var fittedSize = arguments.imageSize
            if abs(fittedSize.width - arguments.boundingSize.width).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.width = arguments.boundingSize.width
            }
            if abs(fittedSize.height - arguments.boundingSize.height).isLessThanOrEqualTo(CGFloat(1.0)) {
                fittedSize.height = arguments.boundingSize.height
            }
            
            let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
            
            var fullSizeImage: CGImage?
            if let fullSizeData = fullSizeData {
                if fullSizeComplete {
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let imageSource = CGImageSourceCreateWithData(fullSizeData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                } else {
                    let imageSource = CGImageSourceCreateIncremental(nil)
                    CGImageSourceUpdateData(imageSource, fullSizeData as CFData, fullSizeComplete)
                    
                    let options = NSMutableDictionary()
                    options[kCGImageSourceShouldCache as NSString] = false as NSNumber
                    if let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) {
                        fullSizeImage = image
                    }
                }
            }
            
            var thumbnailImage: CGImage?
            if let thumbnailData = thumbnailData, let imageSource = CGImageSourceCreateWithData(thumbnailData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                thumbnailImage = image
            }
            
            var blurredThumbnailImage: CGImage?
            if let thumbnailImage = thumbnailImage {
                let thumbnailSize = CGSize(width: thumbnailImage.width, height: thumbnailImage.height)
                let thumbnailContextSize = thumbnailSize.aspectFitted(CGSize(width: 150.0, height: 150.0))
                let thumbnailContext = DrawingContext(size: thumbnailContextSize, scale: 1.0)
                thumbnailContext.withFlippedContext { c in
                    c.interpolationQuality = .none
                    c.draw(thumbnailImage, in: CGRect(origin: CGPoint(), size: thumbnailContextSize))
                }
                telegramFastBlur(Int32(thumbnailContextSize.width), Int32(thumbnailContextSize.height), Int32(thumbnailContext.bytesPerRow), thumbnailContext.bytes)
                
                blurredThumbnailImage = thumbnailContext.generateImage()
            }
            
            
            if let combinedColor = arguments.emptyColor {
                let color = combinedColor.withAlphaComponent(1.0)
                let intensity = combinedColor.alpha
                
                if fullSizeImage == nil {
                    let context = DrawingContext(size: arguments.drawingSize, scale: 1.0, clear: true)
                    context.withFlippedContext { c in
                        c.setBlendMode(.copy)
                        c.setFillColor(color.cgColor)
                        c.fill(arguments.drawingRect)
                    }
                    
                    addCorners(context, arguments: arguments, scale: scale)
                    
                    return context
                }
                
                let context = DrawingContext(size: arguments.drawingSize, scale: scale, clear: true)
                context.withFlippedContext { c in
                    c.setBlendMode(.copy)
                    c.setFillColor(color.cgColor)
                    c.fill(arguments.drawingRect)
                    
                    if let fullSizeImage = fullSizeImage {
                        c.setBlendMode(.normal)
                        c.interpolationQuality = .medium
                        c.clip(to: fittedRect, mask: fullSizeImage)
                        c.setFillColor(patternColor(for: color, intensity: intensity, prominent: prominent).cgColor)
                        c.fill(arguments.drawingRect)
                    }
                }
                
                addCorners(context, arguments: arguments, scale: scale)
                
                return context
            } else {
                context.withFlippedContext(isHighQuality: fullSizeImage != nil, { c in
                    c.setBlendMode(.copy)
                    if arguments.imageSize.width < arguments.boundingSize.width || arguments.imageSize.height < arguments.boundingSize.height {
                        //c.setFillColor(NSColor(white: 0.0, alpha: 0.4).cgColor)
                        c.fill(arguments.drawingRect)
                    }
                    
                    c.setBlendMode(.copy)
                    if let blurredThumbnailImage = blurredThumbnailImage {
                        c.interpolationQuality = .low
                        c.draw(blurredThumbnailImage, in: fittedRect)
                        c.setBlendMode(.normal)
                    }
                    
                    if let fullSizeImage = fullSizeImage {
                        c.interpolationQuality = .medium
                        c.draw(fullSizeImage, in: fittedRect)
                    }
                })

                addCorners(context, arguments: arguments, scale: scale)
                
                return context
            }
        }
    }
}


func instantPageImageFile(account: Account, fileReference: FileMediaReference, scale: CGFloat, fetched: Bool = false) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    return chatMessageFileDatas(account: account, fileReference: fileReference, progressive: false)
        |> map { (thumbnailData, fullSizePath, fullSizeComplete) in
            return { arguments in
                assertNotOnMainThread()
                let context = DrawingContext(size: arguments.drawingSize, scale: scale, clear: true)
                
                let drawingRect = arguments.drawingRect
                let fittedSize = arguments.imageSize.aspectFilled(arguments.boundingSize).fitted(arguments.imageSize)
                
                var fullSizeImage: CGImage?
                var imageOrientation: ImageOrientation = .up
                if let fullSizePath = fullSizePath {
                    if fullSizeComplete {
                        let options = NSMutableDictionary()
                        options.setValue(max(fittedSize.width * context.scale, fittedSize.height * context.scale) as NSNumber, forKey: kCGImageSourceThumbnailMaxPixelSize as String)
                        options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)
                        if let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: fullSizePath) as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options) {
                            imageOrientation = imageOrientationFromSource(imageSource)
                            fullSizeImage = image
                        }
                    }
                }
                
                let fittedRect = CGRect(origin: CGPoint(x: drawingRect.origin.x + (drawingRect.size.width - fittedSize.width) / 2.0, y: drawingRect.origin.y + (drawingRect.size.height - fittedSize.height) / 2.0), size: fittedSize)
                
                context.withFlippedContext { c in
                    if var fullSizeImage = fullSizeImage {
                        if let color = arguments.emptyColor, imageRequiresInversion(fullSizeImage), let tintedImage = generateTintedImage(image: fullSizeImage, color: color) {
                            fullSizeImage = tintedImage
                        }
                        
                        c.setBlendMode(.normal)
                        c.interpolationQuality = .medium
                        
                        drawImage(context: c, image: fullSizeImage, orientation: imageOrientation, in: fittedRect)
                    }
                }
                
                addCorners(context, arguments: arguments, scale: scale)
                
                return context
            }
    }
}

private func rotationFor(_ orientation: ImageOrientation) -> CGFloat {
    switch orientation {
    case .left:
        return CGFloat.pi / 2.0
    case .right:
        return -CGFloat.pi / 2.0
    case .down:
        return -CGFloat.pi
    default:
        return 0.0
    }
}

func drawImage(context: CGContext, image: CGImage, orientation: ImageOrientation, in rect: CGRect) {
    var restore = true
    var drawRect = rect
    switch orientation {
    case .left:
        fallthrough
    case .right:
        fallthrough
    case .down:
        let angle = rotationFor(orientation)
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: angle)
        context.translateBy(x: -rect.midX, y: -rect.midY)
        var t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
        t = t.rotated(by: angle)
        t = t.translatedBy(x: -rect.midX, y: -rect.midY)
        
        drawRect = rect.applying(t)
    case .leftMirrored:
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: -CGFloat.pi / 2.0)
        context.translateBy(x: -rect.midX, y: -rect.midY)
        var t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
        t = t.rotated(by: -CGFloat.pi / 2.0)
        t = t.translatedBy(x: -rect.midX, y: -rect.midY)
        
        drawRect = rect.applying(t)
    default:
        restore = false
    }
    context.draw(image, in: drawRect)
    if restore {
        context.restoreGState()
    }
}

func chatMessageAnimationData(postbox: Postbox, fileReference: FileMediaReference, synchronousLoad: Bool) -> Signal<MediaResourceData, NoError> {
    let maybeFetched = postbox.mediaBox.cachedResourceRepresentation(fileReference.media.resource, representation: CachedAnimatedStickerRepresentation(), pathExtension: "mp4", complete: false, fetch: true, attemptSynchronously: synchronousLoad)
    
    return maybeFetched
        |> take(1)
        |> mapToSignal { maybeData in
            if maybeData.complete {
                return .single(maybeData)
            } else {
                return postbox.mediaBox.cachedResourceRepresentation(fileReference.media.resource, representation: CachedAnimatedStickerRepresentation(), pathExtension: "mp4", complete: false)
            }
    }
}


func mapResourceToAvatarSizes(postbox: Postbox, resource: MediaResource, representations: [TelegramMediaImageRepresentation]) -> Signal<[Int: Data], NoError> {
    return postbox.mediaBox.resourceData(resource)
        |> take(1)
        |> map { data -> [Int: Data] in
            guard data.complete, let image = NSImage(contentsOfFile: data.path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return [:]
            }
            
            let options = NSMutableDictionary()
            options.setValue(true as NSNumber, forKey: kCGImageSourceCreateThumbnailFromImageAlways as String)
            
            let colorQuality: Float = 0.6
            options.setObject(colorQuality as NSNumber, forKey: kCGImageDestinationLossyCompressionQuality as NSString)
            
            var result: [Int: Data] = [:]
            for i in 0 ..< representations.count {
                if let scaledImage = generateScaledImage(image: image, size: representations[i].dimensions, scale: 1.0) {
                    
                    let mutableData: CFMutableData = NSMutableData() as CFMutableData
                    if let colorDestination = CGImageDestinationCreateWithData(mutableData, kUTTypeJPEG, 1, options) {
                        CGImageDestinationSetProperties(colorDestination, nil)
                        
                        CGImageDestinationAddImage(colorDestination, scaledImage, options as CFDictionary)
                        if CGImageDestinationFinalize(colorDestination) {
                           
                        }
                    }
                    
                    result[i] = mutableData as Data
                }
            }
            return result
    }
}


public func generateScaledImage(image: CGImage?, size: CGSize, scale: CGFloat? = nil) -> CGImage? {
    guard let image = image else {
        return nil
    }
    
    return generateImage(size, contextGenerator: { size, context in
        context.draw(image, in: CGRect(origin: CGPoint(), size: size))
    }, opaque: true)
}


private func imageBuffer(from data: UnsafeMutableRawPointer!, width: vImagePixelCount, height: vImagePixelCount, rowBytes: Int) -> vImage_Buffer {
    return vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
}

func blurredImage(_ image: CGImage, radius: CGFloat, iterations: Int = 3) -> CGImage? {
    guard let providerData = image.dataProvider?.data else {
        return nil
    }
    
    if image.size.width <= 0.0 || image.size.height <= 0 || radius <= 0 {
        return image
    }
    
    var boxSize = UInt32(radius)
    if boxSize % 2 == 0 {
        boxSize += 1
    }
    
    let bytes = image.bytesPerRow * image.height
    let inData = malloc(bytes)
    var inBuffer = imageBuffer(from: inData, width: vImagePixelCount(image.width), height: vImagePixelCount(image.height), rowBytes: image.bytesPerRow)
    
    let outData = malloc(bytes)
    var outBuffer = imageBuffer(from: outData, width: vImagePixelCount(image.width), height: vImagePixelCount(image.height), rowBytes: image.bytesPerRow)
    
    let tempSize = vImageBoxConvolve_ARGB8888(&inBuffer, &outBuffer, nil, 0, 0, boxSize, boxSize, nil, vImage_Flags(kvImageEdgeExtend + kvImageGetTempBufferSize))
    let tempData = malloc(tempSize)
    
    defer {
        free(inData)
        free(outData)
        free(tempData)
    }
    
    let source = CFDataGetBytePtr(providerData)
    memcpy(inBuffer.data, source, bytes)
    
    for _ in 0 ..< iterations {
        vImageBoxConvolve_ARGB8888(&inBuffer, &outBuffer, tempData, 0, 0, boxSize, boxSize, nil, vImage_Flags(kvImageEdgeExtend))
        
        let temp = inBuffer.data
        inBuffer.data = outBuffer.data
        outBuffer.data = temp
    }
    
    let context = image.colorSpace.flatMap {
        CGContext(data: inBuffer.data, width: image.width, height: image.height, bitsPerComponent: image.bitsPerComponent, bytesPerRow: image.bytesPerRow, space: $0, bitmapInfo: image.bitmapInfo.rawValue)
    }
    
    let blurredCGImage = context?.makeImage()
    if let blurredCGImage = blurredCGImage {
        return blurredCGImage
    } else {
        return nil
    }
}





func patternColor(for color: NSColor, intensity: CGFloat, prominent: Bool = false) -> NSColor {
    var hue:  CGFloat = 0.0
    var saturation: CGFloat = 0.0
    var brightness: CGFloat = 0.0
    var alpha: CGFloat = 0.0
    color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    if brightness > 0.5 {
        brightness = max(0.0, brightness * 0.65)
    } else {
        brightness = max(0.0, min(1.0, 1.0 - brightness * 0.65))
    }
    saturation = min(1.0, saturation + 0.05 + 0.1 * (1.0 - saturation))
    alpha = (prominent ? 0.5 : 0.4) * intensity
    return NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
}

func solidColor(_ color: NSColor, scale: CGFloat) -> Signal<(TransformImageArguments) -> DrawingContext?, NoError> {
    return .single({ arguments in
        let context = DrawingContext(size: arguments.drawingSize, scale: scale, clear: true)
        
        context.withFlippedContext { c in
            c.setFillColor(color.cgColor)
            c.fill(arguments.drawingRect)
        }
        
        addCorners(context, arguments: arguments, scale: scale)
        
        return context
    })
}



func prepareTextAttachments(_ attachments: [NSTextAttachment]) -> Signal<[URL], NoError> {
    return Signal { subscriber in
        
        var cancelled: Bool = false
        
        resourcesQueue.async {
            var urls:[URL] = []

            for attachment in attachments {
                if cancelled {
                    for url in urls {
                        try? FileManager.default.removeItem(at: url)
                    }
                    subscriber.putCompletion()
                    return
                }
                if let fileWrapper = attachment.fileWrapper {
                    if let data = fileWrapper.regularFileContents {
                        if let fileName = fileWrapper.filename {
                            let path = NSTemporaryDirectory() + fileName
                            var newPath = path
                            var i:Int = 0
                            if FileManager.default.fileExists(atPath: newPath) {
                                newPath = path.nsstring.deletingPathExtension + "\(i)." + path.nsstring.pathExtension
                                i += 1
                            }
                            let url = URL(fileURLWithPath: newPath)
                            do {
                                try data.write(to: url)
                                urls.append(url)
                            } catch {}
                        }
                    }
                }
            }
            subscriber.putNext(urls)
            subscriber.putCompletion()
        }
        
        return ActionDisposable {
            cancelled = true
        }
    } |> runOn(prepareQueue)
}
