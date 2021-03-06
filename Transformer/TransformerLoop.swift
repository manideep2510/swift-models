// Copyright 2020 The TensorFlow Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import ModelSupport
import TensorFlow
import TextModels
import Transformer

internal class GPT2 {
    private static let remoteCheckpoint: URL =
        URL(string: "https://storage.googleapis.com/gpt-2/models/117M/model.ckpt")!

    enum GPT2Error: Error {
        case invalidEncoding(id: Int32)
    }

    let model: TransformerLM
    let bpe: BytePairEncoder

    public var seed: Tensor<Int32>
    public var temperature: Float = 1.0

    var states: [AttentionContext]

    public init(checkpoint: URL = GPT2.remoteCheckpoint) throws {
        let auxiliary: [String] = [
            "checkpoint",
            "encoder.json",
            "hparams.json",
            "model.ckpt.meta",
            "vocab.bpe",
        ]
        let FS: FileManager = FileManager.default
        let storage: URL = FS.temporaryDirectory.appendingPathComponent("Transformer")

        let reader: CheckpointReader = try CheckpointReader(
            checkpointLocation: checkpoint,
            modelName: "Transformer",
            additionalFiles: auxiliary)

        // Load model from configuration
        let hparamsFile: URL = storage.appendingPathComponent("hparams.json")
        let configuration: (file: URL, data: Data) = try (
            hparamsFile, Data(contentsOf: hparamsFile)
        )

        let parameters: TransformerLMConfig = try JSONDecoder().decode(
            TransformerLMConfig.self,
            from: configuration.data)
        model = TransformerLM(reader: reader, config: parameters, scope: "model")

        // Load existing token mappings
        let vocabularyFileURL: URL = storage.appendingPathComponent("encoder.json")
        let vocabulary: (file: URL, data: Data) = try (
            vocabularyFileURL, Data(contentsOf: vocabularyFileURL)
        )

        // Load existing merge pairs
        let mergesFileURL: URL = storage.appendingPathComponent("vocab.bpe")
        let merges: (file: URL, data: Data) = try (mergesFileURL, Data(contentsOf: mergesFileURL))

        // Create bytepair encoder with loaded token mappings
        bpe = try BytePairEncoder(
            vocabularyFile: vocabulary.file, mergesFile: merges.file)

        // ...
        let seedId = Int32(bpe.vocabulary.id(forToken: "<|endoftext|>")!)
        seed = Tensor(shape: [1, 1], scalars: [seedId])
        let empty =
            Tensor<Float>(zeros: [
                parameters.headCount, 0,
                parameters.embeddingSize / parameters.headCount,
            ])
        states = (0..<parameters.layerCount).map { _ in
            AttentionContext(key: empty, value: empty)
        }
    }

    func embedding(for string: String) -> Tensor<Int32> {
        let tokens = bpe.encode(token: string, variant: .gpt2)
        // TODO(michellecasbon): Decide how to prevent OOV or choose a better ID (probably not 0).
        let ids = tokens.map { Int32(bpe.vocabulary.id(forToken: $0) ?? 0) }
        return Tensor(shape: [1, ids.count], scalars: ids)
    }

    func generate() throws -> String {
        let result = model(seed, states: &states)

        let (batchSize, timesteps, vocabularySize) =
            (result.shape[0], result.shape[1], result.shape[2])
        let logits =
            result.slice(
                lowerBounds: [0, timesteps - 1, 0],
                upperBounds: [batchSize, timesteps, vocabularySize]) / temperature
        seed = Tensor(
            randomCategorialLogits: logits.squeezingShape(at: 1),
            sampleCount: 1)

        let id = Int32(seed[0][0])!
        if let token: String = bpe.vocabulary.token(forId: Int(id)) {
            return BytePairEncoder.decode(token: token)
        }

        throw GPT2Error.invalidEncoding(id: id)
    }

    func writeCheckpoint(to location: URL, name: String) throws {
        var tensors = [String: Tensor<Float>]()
        recursivelyObtainTensors(model, scope: "model", tensors: &tensors, separator: "/")

        let writer = CheckpointWriter(tensors: tensors)
        try writer.write(to: location, name: name)
    }
}
