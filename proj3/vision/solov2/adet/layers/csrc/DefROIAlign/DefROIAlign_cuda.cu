#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>
#include <c10/cuda/CUDAGuard.h>
#include <ATen/cuda/CUDAApplyUtils.cuh>

// TODO make it in a common file
#define CUDA_1D_KERNEL_LOOP(i, n)                            \
  for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < n; \
       i += blockDim.x * gridDim.x)


template <typename T>
__device__ T bilinear_interpolate(
    const T* bottom_data,
    const int height,
    const int width,
    T y,
    T x,
    const int index /* index for debug only*/) {
  // deal with cases that inverse elements are out of feature map boundary
  if (y < -1.0 || y > height || x < -1.0 || x > width) {
    // empty
    return 0;
  }

  if (y <= 0)
    y = 0;
  if (x <= 0)
    x = 0;

  int y_low = (int)y;
  int x_low = (int)x;
  int y_high;
  int x_high;

  if (y_low >= height - 1) {
    y_high = y_low = height - 1;
    y = (T)y_low;
  } else {
    y_high = y_low + 1;
  }

  if (x_low >= width - 1) {
    x_high = x_low = width - 1;
    x = (T)x_low;
  } else {
    x_high = x_low + 1;
  }

  T ly = y - y_low;
  T lx = x - x_low;
  T hy = 1. - ly, hx = 1. - lx;
  // do bilinear interpolation
  T v1 = bottom_data[y_low * width + x_low];
  T v2 = bottom_data[y_low * width + x_high];
  T v3 = bottom_data[y_high * width + x_low];
  T v4 = bottom_data[y_high * width + x_high];
  T w1 = hy * hx, w2 = hy * lx, w3 = ly * hx, w4 = ly * lx;

  T val = (w1 * v1 + w2 * v2 + w3 * v3 + w4 * v4);

  return val;
}

template <typename T>
__global__ void DefRoIAlignForward(
    const int nthreads,
    const T* bottom_data,
    const T spatial_scale,
    const int channels,
    const int height,
    const int width,
    const int pooled_height,
    const int pooled_width,
    const int sampling_ratio,
    const T* bottom_rois,
    const T* bottom_trans,  // def added
    const T trans_std,  // def added
    T* top_data,
    bool aligned) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    // (n, c, ph, pw) is an element in the pooled output
    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % channels;
    int n = index / pooled_width / pooled_height / channels;

    const T* offset_bottom_rois = bottom_rois + n * 5;
    int roi_batch_ind = offset_bottom_rois[0];

    // Do not use rounding; this implementation detail is critical
    T offset = aligned ? (T)0.5 : (T)0.0;
    T roi_start_w = offset_bottom_rois[1] * spatial_scale - offset;
    T roi_start_h = offset_bottom_rois[2] * spatial_scale - offset;
    T roi_end_w = offset_bottom_rois[3] * spatial_scale - offset;
    T roi_end_h = offset_bottom_rois[4] * spatial_scale - offset;

    T roi_width = roi_end_w - roi_start_w;
    T roi_height = roi_end_h - roi_start_h;
    if (!aligned) { // for backward-compatibility only
      roi_width = max(roi_width, (T)1.);
      roi_height = max(roi_height, (T)1.);
    }
    T bin_size_h = static_cast<T>(roi_height) / static_cast<T>(pooled_height);
    T bin_size_w = static_cast<T>(roi_width) / static_cast<T>(pooled_width);

    const T* offset_bottom_data =
        bottom_data + (roi_batch_ind * channels + c) * height * width;

    // We use roi_bin_grid to sample the grid and mimic integral
    int roi_bin_grid_h = (sampling_ratio > 0)
        ? sampling_ratio
        : ceil(roi_height / pooled_height); // e.g., = 2
    int roi_bin_grid_w =
        (sampling_ratio > 0) ? sampling_ratio : ceil(roi_width / pooled_width);

    // roi output is the same size
    T trans_x = bottom_trans[((n * 2) * pooled_height + ph) * pooled_width + pw] * trans_std;
    T trans_y = bottom_trans[((n * 2 + 1) * pooled_height + ph) * pooled_width + pw] * trans_std;

    // We do average (integral) pooling inside a bin
    // When the grid is empty, output zeros == 0/1, instead of NaN.
    // Should make bin size adaptive as well
    const T count = max(roi_bin_grid_h * roi_bin_grid_w, 1); // e.g. = 4

    T output_val = 0.;
    for (int iy = 0; iy < roi_bin_grid_h; iy++) // e.g., iy = 0, 1
    {
      const T y = roi_start_h + ph * bin_size_h + trans_y * roi_height +
          static_cast<T>(iy + .5f) * bin_size_h /
              static_cast<T>(roi_bin_grid_h); // e.g., 0.5, 1.5
      for (int ix = 0; ix < roi_bin_grid_w; ix++) {
        const T x = roi_start_w + pw * bin_size_w + trans_x * roi_width +
            static_cast<T>(ix + .5f) * bin_size_w /
                static_cast<T>(roi_bin_grid_w);

        T val = bilinear_interpolate(
            offset_bottom_data, height, width, y, x, index);
        output_val += val;
      }
    }
    output_val /= count;

    top_data[index] = output_val;
  }
}

template <typename T>
__device__ void bilinear_interpolate_gradient(
    const int height,
    const int width,
    T y,
    T x,
    T& w1,
    T& w2,
    T& w3,
    T& w4,
    int& x_low,
    int& x_high,
    int& y_low,
    int& y_high,
    const int index /* index for debug only*/) {
  // deal with cases that inverse elements are out of feature map boundary
  if (y < -1.0 || y > height || x < -1.0 || x > width) {
    // empty
    w1 = w2 = w3 = w4 = 0.;
    x_low = x_high = y_low = y_high = -1;
    return;
  }

  if (y <= 0)
    y = 0;
  if (x <= 0)
    x = 0;

  y_low = (int)y;
  x_low = (int)x;

  if (y_low >= height - 1) {
    y_high = y_low = height - 1;
    y = (T)y_low;
  } else {
    y_high = y_low + 1;
  }

  if (x_low >= width - 1) {
    x_high = x_low = width - 1;
    x = (T)x_low;
  } else {
    x_high = x_low + 1;
  }

  T ly = y - y_low;
  T lx = x - x_low;
  T hy = 1. - ly, hx = 1. - lx;

  // reference in forward
  // T v1 = bottom_data[y_low * width + x_low];
  // T v2 = bottom_data[y_low * width + x_high];
  // T v3 = bottom_data[y_high * width + x_low];
  // T v4 = bottom_data[y_high * width + x_high];
  // T val = (w1 * v1 + w2 * v2 + w3 * v3 + w4 * v4);

  w1 = hy * hx, w2 = hy * lx, w3 = ly * hx, w4 = ly * lx;

  return;
}

template <typename T>
__global__ void DefRoIAlignBackwardFeature(
    const int nthreads,
    const T* top_diff,
    const int num_rois,
    const T spatial_scale,
    const int channels,
    const int height,
    const int width,
    const int pooled_height,
    const int pooled_width,
    const int sampling_ratio,
    T* bottom_diff,
    T* bottom_trans_diff,  // added for deformable
    const T* bottom_data,  // added for deformable
    const T* bottom_rois,
    const T* bottom_trans,  // added for deformable
    const T trans_std, // added for deformable
    bool aligned) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    // (n, c, ph, pw) is an element in the pooled output
    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % channels;
    int n = index / pooled_width / pooled_height / channels;

    const T* offset_bottom_rois = bottom_rois + n * 5;
    int roi_batch_ind = offset_bottom_rois[0];

    // Do not use rounding; this implementation detail is critical
    T offset = aligned ? (T)0.5 : (T)0.0;
    T roi_start_w = offset_bottom_rois[1] * spatial_scale - offset;
    T roi_start_h = offset_bottom_rois[2] * spatial_scale - offset;
    T roi_end_w = offset_bottom_rois[3] * spatial_scale - offset;
    T roi_end_h = offset_bottom_rois[4] * spatial_scale - offset;

    T roi_width = roi_end_w - roi_start_w;
    T roi_height = roi_end_h - roi_start_h;
    if (!aligned) { // for backward-compatibility only
      roi_width = max(roi_width, (T)1.);
      roi_height = max(roi_height, (T)1.);
    }
    T bin_size_h = static_cast<T>(roi_height) / static_cast<T>(pooled_height);
    T bin_size_w = static_cast<T>(roi_width) / static_cast<T>(pooled_width);

    T* offset_bottom_diff =
        bottom_diff + (roi_batch_ind * channels + c) * height * width;

    // compute input data location for offset gradient
    const T* offset_bottom_data =
        bottom_data + (roi_batch_ind * channels + c) * height * width;


    int top_offset = (n * channels + c) * pooled_height * pooled_width;
    const T* offset_top_diff = top_diff + top_offset;
    const T top_diff_this_bin = offset_top_diff[ph * pooled_width + pw];

    // We use roi_bin_grid to sample the grid and mimic integral
    int roi_bin_grid_h = (sampling_ratio > 0)
        ? sampling_ratio
        : ceil(roi_height / pooled_height); // e.g., = 2
    int roi_bin_grid_w =
        (sampling_ratio > 0) ? sampling_ratio : ceil(roi_width / pooled_width);

    T trans_x = bottom_trans[((n * 2) * pooled_height + ph) * pooled_width + pw] * trans_std;
    T trans_y = bottom_trans[((n * 2 + 1) * pooled_height + ph) * pooled_width + pw] * trans_std;

    // We do average (integral) pooling inside a bin
    const T count = roi_bin_grid_h * roi_bin_grid_w; // e.g. = 4

    for (int iy = 0; iy < roi_bin_grid_h; iy++) // e.g., iy = 0, 1
    {
      const T y = roi_start_h + ph * bin_size_h + trans_y * roi_height +
          static_cast<T>(iy + .5f) * bin_size_h /
              static_cast<T>(roi_bin_grid_h); // e.g., 0.5, 1.5
      for (int ix = 0; ix < roi_bin_grid_w; ix++) {
        const T x = roi_start_w + pw * bin_size_w + trans_x * roi_width +
            static_cast<T>(ix + .5f) * bin_size_w /
                static_cast<T>(roi_bin_grid_w);

        T w1, w2, w3, w4;
        int x_low, x_high, y_low, y_high;

        bilinear_interpolate_gradient(
            height,
            width,
            y,
            x,
            w1,
            w2,
            w3,
            w4,
            x_low,
            x_high,
            y_low,
            y_high,
            index);

        T g1 = top_diff_this_bin * w1 / count;
        T g2 = top_diff_this_bin * w2 / count;
        T g3 = top_diff_this_bin * w3 / count;
        T g4 = top_diff_this_bin * w4 / count;

        if (x_low >= 0 && x_high >= 0 && y_low >= 0 && y_high >= 0) {
          atomicAdd(
              offset_bottom_diff + y_low * width + x_low, static_cast<T>(g1));
          atomicAdd(
              offset_bottom_diff + y_low * width + x_high, static_cast<T>(g2));
          atomicAdd(
              offset_bottom_diff + y_high * width + x_low, static_cast<T>(g3));
          atomicAdd(
              offset_bottom_diff + y_high * width + x_high, static_cast<T>(g4));

          T U00 = offset_bottom_data[y_low * width + x_low];
          T U01 = offset_bottom_data[y_high * width + x_low];
          T U10 = offset_bottom_data[y_low * width + x_high];
          T U11 = offset_bottom_data[y_high * width + x_high];
          T dist_x = x - x_low, dist_y = y - y_low;
          T diff_val = top_diff_this_bin / count;
          T diff_x = (U11 * dist_y + U10 * (1 - dist_y) - U01 * dist_y - U00 * (1 - dist_y)) * trans_std * diff_val;
          diff_x *= roi_width;
          T diff_y = (U11 * dist_x + U01 * (1 - dist_x) - U10 * dist_x - U00 * (1 - dist_x)) * trans_std * diff_val;
          diff_y *= roi_height;

          atomicAdd(bottom_trans_diff + ((n * 2) * pooled_height + ph) * pooled_width + pw, diff_x);
          atomicAdd(bottom_trans_diff + ((n * 2 + 1) * pooled_height + ph) * pooled_width + pw, diff_y);
        } // if
      } // ix
    } // iy
  } // CUDA_1D_KERNEL_LOOP
} // RoIAlignBackward

namespace adet {

at::Tensor DefROIAlign_forward_cuda(
    const at::Tensor& input,
    const at::Tensor& rois,
    const at::Tensor& offsets,  // def added
    const float spatial_scale,
    const int pooled_height,
    const int pooled_width,
    const int sampling_ratio,
    const float trans_std,  // def added
    bool aligned) {
  AT_ASSERTM(input.device().is_cuda(), "input must be a CUDA tensor");
  AT_ASSERTM(rois.device().is_cuda(), "rois must be a CUDA tensor");
  AT_ASSERTM(offsets.device().is_cuda(), "offsets must be a CUDA tensor");
  at::TensorArg input_t{input, "input", 1}, rois_t{rois, "rois", 2}, offsets_t{offsets, "offsets", 3};

  at::CheckedFrom c = "DefROIAlign_forward_cuda";
  at::checkAllSameGPU(c, {input_t, rois_t, offsets_t});
  at::checkAllSameType(c, {input_t, rois_t, offsets_t});
  at::cuda::CUDAGuard device_guard(input.device());

  auto num_rois = rois.size(0);
  auto channels = input.size(1);
  auto height = input.size(2);
  auto width = input.size(3);

  auto output = at::empty(
      {num_rois, channels, pooled_height, pooled_width}, input.options());
  auto output_size = num_rois * pooled_height * pooled_width * channels;
  cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  dim3 grid(std::min(
      at::cuda::ATenCeilDiv(
          static_cast<int64_t>(output_size), static_cast<int64_t>(512)),
      static_cast<int64_t>(4096)));
  dim3 block(512);

  if (output.numel() == 0) {
    AT_CUDA_CHECK(cudaGetLastError());
    return output;
  }

  AT_DISPATCH_FLOATING_TYPES(input.scalar_type(), "DefROIAlign_forward", [&] {
    DefRoIAlignForward<scalar_t><<<grid, block, 0, stream>>>(
        output_size,
        input.contiguous().data_ptr<scalar_t>(),
        spatial_scale,
        channels,
        height,
        width,
        pooled_height,
        pooled_width,
        sampling_ratio,
        rois.contiguous().data_ptr<scalar_t>(),
        offsets.contiguous().data_ptr<scalar_t>(),  // def added
        trans_std,  //def added
        output.data_ptr<scalar_t>(),
        aligned);
  });
  cudaDeviceSynchronize();
  AT_CUDA_CHECK(cudaGetLastError());
  return output;
}

// TODO remove the dependency on input and use instead its sizes -> save memory
at::Tensor DefROIAlign_backward_cuda(
    const at::Tensor& input,  // def added
    const at::Tensor& grad,
    const at::Tensor& rois,
    const at::Tensor& offsets,  // def added
    const at::Tensor& grad_offsets,  // def added
    const float spatial_scale,
    const int pooled_height,
    const int pooled_width,
    const int batch_size,
    const int channels,
    const int height,
    const int width,
    const int sampling_ratio,
    const float trans_std,  // def added
    bool aligned) {
  AT_ASSERTM(grad.device().is_cuda(), "grad must be a CUDA tensor");
  AT_ASSERTM(rois.device().is_cuda(), "rois must be a CUDA tensor");
  AT_ASSERTM(input.device().is_cuda(), "input must be a CUDA tensor");
  AT_ASSERTM(offsets.device().is_cuda(), "offsets must be a CUDA tensor");

  at::TensorArg grad_t{grad, "grad", 1}, rois_t{rois, "rois", 2}, input_t{input, "input", 3}, offsets_t{offsets, "offsets", 4};
  at::CheckedFrom c = "DefROIAlign_backward_cuda";
  at::checkAllSameGPU(c, {grad_t, rois_t, input_t, offsets_t});
  at::checkAllSameType(c, {grad_t, rois_t, input_t, offsets_t});
  at::cuda::CUDAGuard device_guard(grad.device());

  auto num_rois = rois.size(0);
  auto grad_input =
      at::zeros({batch_size, channels, height, width}, grad.options());

  cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  dim3 grid(std::min(
      at::cuda::ATenCeilDiv(
          static_cast<int64_t>(grad.numel()), static_cast<int64_t>(512)),
      static_cast<int64_t>(4096)));
  dim3 block(512);

  // handle possibly empty gradients
  if (grad.numel() == 0) {
    AT_CUDA_CHECK(cudaGetLastError());
    return grad_input;
  }

  AT_DISPATCH_FLOATING_TYPES(grad.scalar_type(), "DefROIAlign_backward", [&] {
    DefRoIAlignBackwardFeature<scalar_t><<<grid, block, 0, stream>>>(
        grad.numel(),
        grad.contiguous().data_ptr<scalar_t>(),
        num_rois,
        spatial_scale,
        channels,
        height,
        width,
        pooled_height,
        pooled_width,
        sampling_ratio,
        grad_input.data_ptr<scalar_t>(),
        grad_offsets.data_ptr<scalar_t>(),  // def added
        input.contiguous().data_ptr<scalar_t>(), // def added
        rois.contiguous().data_ptr<scalar_t>(),
        offsets.contiguous().data_ptr<scalar_t>(), // def added
        trans_std,  // def added
        aligned);
  });
  AT_CUDA_CHECK(cudaGetLastError());
  return grad_input;
}

} // namespace adet
