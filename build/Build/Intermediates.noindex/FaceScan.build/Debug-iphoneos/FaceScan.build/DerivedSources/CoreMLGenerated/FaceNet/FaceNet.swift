//
// FaceNet.swift
//
// This file was automatically generated and should not be edited.
//

import CoreML


/// Model Prediction Input Type
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
class FaceNetInput : MLFeatureProvider {

    /// image as color (kCVPixelFormatType_32BGRA) image buffer, 160 pixels wide by 160 pixels high
    var image: CVPixelBuffer

    var featureNames: Set<String> { ["image"] }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName == "image" {
            return MLFeatureValue(pixelBuffer: image)
        }
        return nil
    }

    init(image: CVPixelBuffer) {
        self.image = image
    }

    convenience init(imageWith image: CGImage) throws {
        self.init(image: try MLFeatureValue(cgImage: image, pixelsWide: 160, pixelsHigh: 160, pixelFormatType: kCVPixelFormatType_32ARGB, options: nil).imageBufferValue!)
    }

    convenience init(imageAt image: URL) throws {
        self.init(image: try MLFeatureValue(imageAt: image, pixelsWide: 160, pixelsHigh: 160, pixelFormatType: kCVPixelFormatType_32ARGB, options: nil).imageBufferValue!)
    }

    func setImage(with image: CGImage) throws  {
        self.image = try MLFeatureValue(cgImage: image, pixelsWide: 160, pixelsHigh: 160, pixelFormatType: kCVPixelFormatType_32ARGB, options: nil).imageBufferValue!
    }

    func setImage(with image: URL) throws  {
        self.image = try MLFeatureValue(imageAt: image, pixelsWide: 160, pixelsHigh: 160, pixelFormatType: kCVPixelFormatType_32ARGB, options: nil).imageBufferValue!
    }

}


/// Model Prediction Output Type
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
class FaceNetOutput : MLFeatureProvider {

    /// Source provided by CoreML
    private let provider : MLFeatureProvider

    /// embedding as 1 by 512 matrix of 16-bit floats
    var embedding: MLMultiArray {
        provider.featureValue(for: "embedding")!.multiArrayValue!
    }

    /// embedding as 1 by 512 matrix of 16-bit floats
    #if (os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64)
    @available(macOS, unavailable)
    @available(macCatalyst, unavailable)
    #else
    @available(macOS 15.0, *)
    #endif
    var embeddingShapedArray: MLShapedArray<Float16> {
        MLShapedArray<Float16>(embedding)
    }

    var featureNames: Set<String> {
        provider.featureNames
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        provider.featureValue(for: featureName)
    }

    init(embedding: MLMultiArray) {
        self.provider = try! MLDictionaryFeatureProvider(dictionary: ["embedding" : MLFeatureValue(multiArray: embedding)])
    }

    init(features: MLFeatureProvider) {
        self.provider = features
    }
}


/// Class for model loading and prediction
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
class FaceNet {
    let model: MLModel

    /// URL of model assuming it was installed in the same bundle as this class
    class var urlOfModelInThisBundle : URL {
        let bundle = Bundle(for: self)
        return bundle.url(forResource: "FaceNet", withExtension:"mlmodelc")!
    }

    /**
        Construct FaceNet instance with an existing MLModel object.

        Usually the application does not use this initializer unless it makes a subclass of FaceNet.
        Such application may want to use `MLModel(contentsOfURL:configuration:)` and `FaceNet.urlOfModelInThisBundle` to create a MLModel object to pass-in.

        - parameters:
          - model: MLModel object
    */
    init(model: MLModel) {
        self.model = model
    }

    /**
        Construct a model with configuration

        - parameters:
           - configuration: the desired model configuration

        - throws: an NSError object that describes the problem
    */
    convenience init(configuration: MLModelConfiguration = MLModelConfiguration()) throws {
        try self.init(contentsOf: type(of:self).urlOfModelInThisBundle, configuration: configuration)
    }

    /**
        Construct FaceNet instance with explicit path to mlmodelc file
        - parameters:
           - modelURL: the file url of the model

        - throws: an NSError object that describes the problem
    */
    convenience init(contentsOf modelURL: URL) throws {
        try self.init(model: MLModel(contentsOf: modelURL))
    }

    /**
        Construct a model with URL of the .mlmodelc directory and configuration

        - parameters:
           - modelURL: the file url of the model
           - configuration: the desired model configuration

        - throws: an NSError object that describes the problem
    */
    convenience init(contentsOf modelURL: URL, configuration: MLModelConfiguration) throws {
        try self.init(model: MLModel(contentsOf: modelURL, configuration: configuration))
    }

    /**
        Construct FaceNet instance asynchronously with optional configuration.

        Model loading may take time when the model content is not immediately available (e.g. encrypted model). Use this factory method especially when the caller is on the main thread.

        - parameters:
          - configuration: the desired model configuration
          - handler: the completion handler to be called when the model loading completes successfully or unsuccessfully
    */
    class func load(configuration: MLModelConfiguration = MLModelConfiguration(), completionHandler handler: @escaping (Swift.Result<FaceNet, Error>) -> Void) {
        load(contentsOf: self.urlOfModelInThisBundle, configuration: configuration, completionHandler: handler)
    }

    /**
        Construct FaceNet instance asynchronously with optional configuration.

        Model loading may take time when the model content is not immediately available (e.g. encrypted model). Use this factory method especially when the caller is on the main thread.

        - parameters:
          - configuration: the desired model configuration
    */
    class func load(configuration: MLModelConfiguration = MLModelConfiguration()) async throws -> FaceNet {
        try await load(contentsOf: self.urlOfModelInThisBundle, configuration: configuration)
    }

    /**
        Construct FaceNet instance asynchronously with URL of the .mlmodelc directory with optional configuration.

        Model loading may take time when the model content is not immediately available (e.g. encrypted model). Use this factory method especially when the caller is on the main thread.

        - parameters:
          - modelURL: the URL to the model
          - configuration: the desired model configuration
          - handler: the completion handler to be called when the model loading completes successfully or unsuccessfully
    */
    class func load(contentsOf modelURL: URL, configuration: MLModelConfiguration = MLModelConfiguration(), completionHandler handler: @escaping (Swift.Result<FaceNet, Error>) -> Void) {
        MLModel.load(contentsOf: modelURL, configuration: configuration) { result in
            switch result {
            case .failure(let error):
                handler(.failure(error))
            case .success(let model):
                handler(.success(FaceNet(model: model)))
            }
        }
    }

    /**
        Construct FaceNet instance asynchronously with URL of the .mlmodelc directory with optional configuration.

        Model loading may take time when the model content is not immediately available (e.g. encrypted model). Use this factory method especially when the caller is on the main thread.

        - parameters:
          - modelURL: the URL to the model
          - configuration: the desired model configuration
    */
    class func load(contentsOf modelURL: URL, configuration: MLModelConfiguration = MLModelConfiguration()) async throws -> FaceNet {
        let model = try await MLModel.load(contentsOf: modelURL, configuration: configuration)
        return FaceNet(model: model)
    }

    /**
        Make a prediction using the structured interface

        It uses the default function if the model has multiple functions.

        - parameters:
           - input: the input to the prediction as FaceNetInput

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as FaceNetOutput
    */
    func prediction(input: FaceNetInput) throws -> FaceNetOutput {
        try prediction(input: input, options: MLPredictionOptions())
    }

    /**
        Make a prediction using the structured interface

        It uses the default function if the model has multiple functions.

        - parameters:
           - input: the input to the prediction as FaceNetInput
           - options: prediction options

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as FaceNetOutput
    */
    func prediction(input: FaceNetInput, options: MLPredictionOptions) throws -> FaceNetOutput {
        let outFeatures = try model.prediction(from: input, options: options)
        return FaceNetOutput(features: outFeatures)
    }

    /**
        Make an asynchronous prediction using the structured interface

        It uses the default function if the model has multiple functions.

        - parameters:
           - input: the input to the prediction as FaceNetInput
           - options: prediction options

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as FaceNetOutput
    */
    func prediction(input: FaceNetInput, options: MLPredictionOptions = MLPredictionOptions()) async throws -> FaceNetOutput {
        let outFeatures = try await model.prediction(from: input, options: options)
        return FaceNetOutput(features: outFeatures)
    }

    /**
        Make a prediction using the convenience interface

        It uses the default function if the model has multiple functions.

        - parameters:
            - image: color (kCVPixelFormatType_32BGRA) image buffer, 160 pixels wide by 160 pixels high

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as FaceNetOutput
    */
    func prediction(image: CVPixelBuffer) throws -> FaceNetOutput {
        let input_ = FaceNetInput(image: image)
        return try prediction(input: input_)
    }

    /**
        Make a batch prediction using the structured interface

        It uses the default function if the model has multiple functions.

        - parameters:
           - inputs: the inputs to the prediction as [FaceNetInput]
           - options: prediction options

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as [FaceNetOutput]
    */
    func predictions(inputs: [FaceNetInput], options: MLPredictionOptions = MLPredictionOptions()) throws -> [FaceNetOutput] {
        let batchIn = MLArrayBatchProvider(array: inputs)
        let batchOut = try model.predictions(from: batchIn, options: options)
        var results : [FaceNetOutput] = []
        results.reserveCapacity(inputs.count)
        for i in 0..<batchOut.count {
            let outProvider = batchOut.features(at: i)
            let result =  FaceNetOutput(features: outProvider)
            results.append(result)
        }
        return results
    }
}
