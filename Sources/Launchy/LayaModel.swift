import Foundation
import MLX
import MLXNN

// A translation of Laya's decision model (Apache-2.0) for Launchy's relevance filter: laya-mlx's
// model.py and Laya's common.py, restricted to the one noul question Launchy asks. Credit to Laya
// and laya-mlx. Every size comes from the checkpoint's configs. The row format and the weights'
// names are a contract with the checkpoint (ADR 0006): a mismatch lowers ranking with no error.

/// The encoder's `config.json`. A config without `layer_types` or per-type `rope_parameters` fails to
/// decode, and `validate()` refuses anything the model below doesn't implement.
struct ModernBertConfig: Decodable {
    struct Rope: Decodable {
        let ropeTheta: Float
        let ropeType: String?
        enum CodingKeys: String, CodingKey { case ropeTheta = "rope_theta", ropeType = "rope_type" }
    }
    let modelType: String
    let vocabSize, hiddenSize, intermediateSize, numHiddenLayers, numAttentionHeads, localAttention: Int
    let normEps: Float
    let normBias, attentionBias, mlpBias: Bool
    let hiddenActivation: String
    let layerTypes: [String]
    let ropeParameters: [String: Rope]

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type", vocabSize = "vocab_size", hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size", numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads", localAttention = "local_attention"
        case normEps = "norm_eps", normBias = "norm_bias", attentionBias = "attention_bias", mlpBias = "mlp_bias"
        case hiddenActivation = "hidden_activation", layerTypes = "layer_types", ropeParameters = "rope_parameters"
    }

    func validate() throws {
        guard modelType == "modernbert", hiddenActivation == "gelu", !normBias, !attentionBias, !mlpBias,
              vocabSize > 0, intermediateSize > 0, hiddenSize > 0, numAttentionHeads > 0,
              hiddenSize % numAttentionHeads == 0, hiddenSize % 64 == 0, localAttention >= 2,
              layerTypes.count == numHiddenLayers,
              layerTypes.allSatisfy({ ["full_attention", "sliding_attention"].contains($0) }),
              Set(layerTypes).allSatisfy({ ropeParameters[$0].map { ($0.ropeType ?? "default") == "default" } ?? false })
        else { throw LocalRerankerError.unsupported("The encoder config isn't the ModernBERT this build implements") }
    }
}

// MARK: - Encoder

private final class Embeddings: Module {
    @ModuleInfo(key: "tok_embeddings") var tokEmbeddings: Embedding
    @ModuleInfo var norm: LayerNorm

    init(_ c: ModernBertConfig) {
        _tokEmbeddings.wrappedValue = Embedding(embeddingCount: c.vocabSize, dimensions: c.hiddenSize)
        _norm.wrappedValue = LayerNorm(dimensions: c.hiddenSize, eps: c.normEps, bias: false)
    }

    func callAsFunction(_ ids: MLXArray) -> MLXArray { norm(tokEmbeddings(ids)) }
}

private final class EncoderAttention: Module {
    let heads, headDim: Int
    let theta: Float
    @ModuleInfo(key: "Wqkv") var wqkv: Linear
    @ModuleInfo(key: "Wo") var wo: Linear

    init(_ c: ModernBertConfig, theta: Float) {
        heads = c.numAttentionHeads
        headDim = c.hiddenSize / c.numAttentionHeads
        self.theta = theta
        _wqkv.wrappedValue = Linear(c.hiddenSize, 3 * c.hiddenSize, bias: false)
        _wo.wrappedValue = Linear(c.hiddenSize, c.hiddenSize, bias: false)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray) -> MLXArray {
        let (b, l) = (x.dim(0), x.dim(1))
        let qkv = wqkv(x).reshaped(b, l, 3, heads, headDim)
        // Rotate-half RoPE over the whole head; positions start at 0 in every (right-padded) row.
        let q = MLXFast.RoPE(qkv[0..., 0..., 0].transposed(0, 2, 1, 3), dimensions: headDim,
                             traditional: false, base: theta, scale: 1, offset: 0)
        let k = MLXFast.RoPE(qkv[0..., 0..., 1].transposed(0, 2, 1, 3), dimensions: headDim,
                             traditional: false, base: theta, scale: 1, offset: 0)
        let v = qkv[0..., 0..., 2].transposed(0, 2, 1, 3)
        let out = MLXFast.scaledDotProductAttention(
            queries: q, keys: k, values: v, scale: 1 / Float(headDim).squareRoot(), mask: .array(mask))
        return wo(out.transposed(0, 2, 1, 3).reshaped(b, l, -1))
    }
}

private final class EncoderMLP: Module {
    @ModuleInfo(key: "Wi") var wi: Linear
    @ModuleInfo(key: "Wo") var wo: Linear

    init(_ c: ModernBertConfig) {
        _wi.wrappedValue = Linear(c.hiddenSize, 2 * c.intermediateSize, bias: false)
        _wo.wrappedValue = Linear(c.intermediateSize, c.hiddenSize, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let parts = split(wi(x), parts: 2, axis: -1)   // [input, gate]
        return wo(gelu(parts[0]) * parts[1])           // exact (erf) GELU
    }
}

private final class EncoderLayer: Module {
    let sliding: Bool
    @ModuleInfo(key: "attn_norm") var attnNorm: LayerNorm?   // layer 0 has none
    @ModuleInfo var attn: EncoderAttention
    @ModuleInfo(key: "mlp_norm") var mlpNorm: LayerNorm
    @ModuleInfo var mlp: EncoderMLP

    init(_ c: ModernBertConfig, index: Int) {
        let kind = c.layerTypes[index]
        sliding = kind == "sliding_attention"
        if index > 0 { _attnNorm.wrappedValue = LayerNorm(dimensions: c.hiddenSize, eps: c.normEps, bias: false) }
        // Taken per layer type: this checkpoint uses 160000 for both, not ModernBERT's usual 10000.
        _attn.wrappedValue = EncoderAttention(c, theta: c.ropeParameters[kind]!.ropeTheta)
        _mlpNorm.wrappedValue = LayerNorm(dimensions: c.hiddenSize, eps: c.normEps, bias: false)
        _mlp.wrappedValue = EncoderMLP(c)
    }

    func callAsFunction(_ x: MLXArray, full: MLXArray, local: MLXArray) -> MLXArray {
        let h = x + attn(attnNorm?(x) ?? x, mask: sliding ? local : full)
        return h + mlp(mlpNorm(h))
    }
}

private final class ModernBert: Module {
    let halfWindow: Int
    @ModuleInfo var embeddings: Embeddings
    @ModuleInfo var layers: [EncoderLayer]
    @ModuleInfo(key: "final_norm") var finalNorm: LayerNorm

    init(_ c: ModernBertConfig) {
        halfWindow = c.localAttention / 2
        _embeddings.wrappedValue = Embeddings(c)
        _layers.wrappedValue = (0 ..< c.numHiddenLayers).map { EncoderLayer(c, index: $0) }
        _finalNorm.wrappedValue = LayerNorm(dimensions: c.hiddenSize, eps: c.normEps, bias: false)
    }

    /// `valid` is [B, L], true for real tokens.
    func callAsFunction(_ ids: MLXArray, valid: MLXArray) -> MLXArray {
        let full = valid[0..., .newAxis, .newAxis, 0...]   // a key must be a real token
        // Built here: mlx-swift-lm's sliding-window helper masks by absolute key index, which is a different mask.
        let pos = MLXArray(Int32(0) ..< Int32(ids.dim(1)))
        let band = abs(pos[0..., .newAxis] - pos[.newAxis, 0...]) .<= Int32(halfWindow)
        // A padded query sees every real key, so no softmax row is fully masked (NaN).
        let local = (band[.newAxis, .newAxis] .|| .!valid[0..., .newAxis, 0..., .newAxis]) .&& full
        var x = embeddings(ids)
        for layer in layers { x = layer(x, full: full, local: local) }
        return finalNorm(x)
    }
}

// MARK: - Decision head

private final class HeadAttention: Module {
    let heads: Int
    @ParameterInfo(key: "in_proj_weight") var inProjWeight: MLXArray
    @ParameterInfo(key: "in_proj_bias") var inProjBias: MLXArray
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(width: Int) {
        heads = width / 64
        _inProjWeight.wrappedValue = MLXArray.zeros([3 * width, width])
        _inProjBias.wrappedValue = MLXArray.zeros([3 * width])
        _outProj.wrappedValue = Linear(width, width)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray) -> MLXArray {
        let (b, l, d) = (x.dim(0), x.dim(1), x.dim(2))
        let qkv = addMM(inProjBias, x, inProjWeight.T).reshaped(b, l, 3, heads, d / heads)
        let out = MLXFast.scaledDotProductAttention(
            queries: qkv[0..., 0..., 0].transposed(0, 2, 1, 3), keys: qkv[0..., 0..., 1].transposed(0, 2, 1, 3),
            values: qkv[0..., 0..., 2].transposed(0, 2, 1, 3), scale: 1 / Float(d / heads).squareRoot(),
            mask: .array(mask))
        return outProj(out.transposed(0, 2, 1, 3).reshaped(b, l, d))
    }
}

/// PyTorch's TransformerEncoderLayer with norm_first and ReLU.
private final class HeadLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: HeadAttention
    @ModuleInfo var norm1: LayerNorm
    @ModuleInfo var norm2: LayerNorm
    @ModuleInfo var linear1: Linear
    @ModuleInfo var linear2: Linear

    init(width: Int) {
        _selfAttn.wrappedValue = HeadAttention(width: width)
        _norm1.wrappedValue = LayerNorm(dimensions: width)
        _norm2.wrappedValue = LayerNorm(dimensions: width)
        _linear1.wrappedValue = Linear(width, 4 * width)
        _linear2.wrappedValue = Linear(4 * width, width)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray) -> MLXArray {
        let h = x + selfAttn(norm1(x), mask: mask)
        return h + linear2(relu(linear1(norm2(h))))
    }
}

private final class DecisionHead: Module {
    @ModuleInfo var layers: [HeadLayer]
    init(width: Int, count: Int) { _layers.wrappedValue = (0 ..< count).map { _ in HeadLayer(width: width) } }
}

/// The scorer's last projection runs in fp32, so the logits and their difference keep their precision.
private final class Float32Linear: Linear {
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        matmul(x.asType(.float32), weight.asType(.float32).T) + bias!.asType(.float32)
    }
}

// MARK: - Model

final class LayaModel: Module {
    /// Laya's question type for yes/no judgements; picks the type embedding.
    private static let noul = 2

    @ModuleInfo fileprivate var encoder: ModernBert
    @ModuleInfo fileprivate var head: DecisionHead
    @ModuleInfo(key: "type_emb") fileprivate var typeEmb: Embedding
    // An array of its four layers so PyTorch's numeric names (scorer.0 ...) map directly.
    @ModuleInfo fileprivate var scorer: [UnaryLayer]

    init(_ c: ModernBertConfig, headLayers: Int) {
        let width = c.hiddenSize
        _encoder.wrappedValue = ModernBert(c)
        _head.wrappedValue = DecisionHead(width: width, count: headLayers)
        _typeEmb.wrappedValue = Embedding(embeddingCount: 3, dimensions: width)
        _scorer.wrappedValue = [LayerNorm(dimensions: width), Linear(width, width), GELU(), Float32Linear(width, 1)]
    }

    /// Logits at the two answer markers, [B, 2] fp32, in the order false, true.
    func callAsFunction(_ ids: MLXArray, valid: MLXArray, markers: MLXArray) -> MLXArray {
        var h = encoder(ids, valid: valid) + typeEmb.weight[Self.noul]
        let keys = valid[0..., .newAxis, .newAxis, 0...]
        for layer in head.layers { h = layer(h, mask: keys) }
        var x = h[0..., markers]
        for layer in scorer { x = layer(x) }
        return x.squeezed(axis: -1)
    }

    /// Loads the PyTorch-named safetensors minus the unused action head and temperature; any missing or
    /// extra tensor is an error. Names are compared first because mlx-swift traps on extra layers.
    func loadWeights(from url: URL) throws {
        var weights = [String: MLXArray]()
        for (name, value) in try loadArrays(url: url) where !name.hasPrefix("act_head.") && name != "temperature" {
            weights[name] = value.asType(.float16)
        }
        guard Set(weights.keys) == Set(parameters().flattened().map(\.0)) else {
            throw LocalRerankerError.unsupported("The weights don't match the checkpoint's configs")
        }
        try update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(self)
    }
}
