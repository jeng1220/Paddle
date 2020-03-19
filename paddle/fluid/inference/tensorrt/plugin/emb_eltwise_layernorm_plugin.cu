// Copyright (c) 2018 PaddlePaddle Authors. All Rights Reserved.
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

#include <stdio.h>
#include <cassert>
#include <cub/cub.cuh>  // NOLINT
#include <vector>
#include "glog/logging.h"
#include "paddle/fluid/framework/tensor.h"
#include "paddle/fluid/framework/tensor_util.h"
#include "paddle/fluid/inference/tensorrt/plugin/emb_eltwise_layernorm_plugin.h"
#include "paddle/fluid/inference/tensorrt/plugin/trt_plugin_factory.h"
#include "paddle/fluid/operators/math/bert_encoder_functor.h"

namespace paddle {
namespace inference {
namespace tensorrt {
namespace plugin {

// Dynamic Plugin below.
#if IS_TRT_VERSION_GE(6000)

int EmbEltwiseLayernormPluginDynamic::initialize() {
  cudaMalloc(&word_emb_gpu_, sizeof(float) * word_emb_size_);
  cudaMemcpy(word_emb_gpu_, word_emb_, word_emb_size_ * sizeof(float),
             cudaMemcpyHostToDevice);

  cudaMalloc(&pos_emb_gpu_, sizeof(float) * pos_emb_size_);
  cudaMemcpy(pos_emb_gpu_, pos_emb_, pos_emb_size_ * sizeof(float),
             cudaMemcpyHostToDevice);

  cudaMalloc(&sent_emb_gpu_, sizeof(float) * sent_emb_size_);
  cudaMemcpy(sent_emb_gpu_, sent_emb_, sent_emb_size_ * sizeof(float),
             cudaMemcpyHostToDevice);

  cudaMalloc(&bias_gpu_, sizeof(float) * bias_size_);
  cudaMemcpy(bias_gpu_, bias_, bias_size_ * sizeof(float),
             cudaMemcpyHostToDevice);
  cudaMalloc(&scale_gpu_, sizeof(float) * scale_size_);
  cudaMemcpy(scale_gpu_, scale_, scale_size_ * sizeof(float),
             cudaMemcpyHostToDevice);

  return 0;
}

size_t EmbEltwiseLayernormPluginDynamic::getSerializationSize() const {
  return 0;
}

void EmbEltwiseLayernormPluginDynamic::serialize(void *buffer) const {}

nvinfer1::DimsExprs EmbEltwiseLayernormPluginDynamic::getOutputDimensions(
    int output_index, const nvinfer1::DimsExprs *inputs, int nb_inputs,
    nvinfer1::IExprBuilder &expr_builder) {
  PADDLE_ENFORCE_EQ(output_index, 0,
                    platform::errors::InvalidArgument(
                        "There is only one output of the EmbEltwiseLayernorm, "
                        "so the index should be zero,"
                        "but it's (%d)",
                        output_index));
  PADDLE_ENFORCE_EQ(
      nb_inputs, 3,
      platform::errors::InvalidArgument(
          "The Input of the EmbEltwiseLayernorm should be 3, but we found "
          "it has (%d) inputs",
          nb_inputs));
  nvinfer1::DimsExprs ret;
  ret.nbDims = 5;
  ret.d[0] = inputs[0].d[0];
  ret.d[1] = inputs[0].d[1];
  ret.d[2] = expr_builder.constant(hidden_size_);
  ret.d[3] = expr_builder.constant(1);
  ret.d[4] = expr_builder.constant(1);
  return ret;
}

bool EmbEltwiseLayernormPluginDynamic::supportsFormatCombination(
    int pos, const nvinfer1::PluginTensorDesc *in_out, int nb_inputs,
    int nb_outputs) {
  PADDLE_ENFORCE_NOT_NULL(
      in_out, platform::errors::InvalidArgument(
                  "The input of swish plugin shoule not be nullptr."));

  PADDLE_ENFORCE_LT(
      pos, nb_inputs + nb_outputs,
      platform::errors::InvalidArgument("The pos(%d) should be less than the "
                                        "num(%d) of the input and the output.",
                                        pos, nb_inputs + nb_outputs));
  (in_out && pos < (nb_inputs + nb_outputs));

  const nvinfer1::PluginTensorDesc &desc = in_out[pos];
  if (desc.format != nvinfer1::TensorFormat::kLINEAR) {
    return false;
  }

  if (pos == 0) {
    return desc.type == nvinfer1::DataType::kINT32;
  }

  const nvinfer1::PluginTensorDesc &prev = in_out[pos - 1];
  if (pos == 1 || pos == 2) {
    return desc.type == nvinfer1::DataType::kINT32 &&
           desc.dims.d[0] == prev.dims.d[0] && desc.dims.d[1] == prev.dims.d[1];
  }

  if (pos == 3) {
    return desc.type == nvinfer1::DataType::kFLOAT;
  }
}

nvinfer1::DataType EmbEltwiseLayernormPluginDynamic::getOutputDataType(
    int index, const nvinfer1::DataType *input_types, int nb_inputs) const {
  PADDLE_ENFORCE_EQ(
      index, 0, platform::errors::InvalidArgument(
                    "The EmbEltwiseLayernorm Plugin only has one input, so the "
                    "index value should be 0, but get %d.",
                    index));
  return nvinfer1::DataType::kFLOAT;
}

int EmbEltwiseLayernormPluginDynamic::enqueue(
    const nvinfer1::PluginTensorDesc *input_desc,
    const nvinfer1::PluginTensorDesc *output_desc, const void *const *inputs,
    void *const *outputs, void *workspace, cudaStream_t stream) {
  auto word_id_dims = input_desc[0].dims;
  int batch = word_id_dims.d[0];
  int seq_len = word_id_dims.d[1];

  auto out_type = output_desc[0].type;
  const int64_t *word_id = static_cast<const int64_t *>(inputs[0]);
  const int64_t *pos_id = static_cast<const int64_t *>(inputs[1]);
  const int64_t *sent_id = static_cast<const int64_t *>(inputs[2]);

  const unsigned tpb = 256;
  const dim3 grid(seq_len, batch, 1);
  const dim3 block(tpb, 1, 1);
  PADDLE_ENFORCE_EQ(
      out_type == nvinfer1::DataType::kFLOAT, true,
      platform::errors::InvalidArgument(
          "The EmbEltwiseLayernorm Plugin only only support fp32 input."));

  float *output_d = static_cast<float *>(outputs[0]);
  operators::math::EmbEltwiseLayerNormFunctor<float> emb_eltwise_layernorm_func;
  emb_eltwise_layernorm_func(batch, seq_len, hidden_size_, word_id, pos_id,
                             sent_id, scale_gpu_, bias_gpu_, word_emb_gpu_,
                             pos_emb_gpu_, sent_emb_gpu_, output_d, eps_,
                             stream);
  return cudaGetLastError() != cudaSuccess;
}
#endif

}  // namespace plugin
}  // namespace tensorrt
}  // namespace inference
}  // namespace paddle
