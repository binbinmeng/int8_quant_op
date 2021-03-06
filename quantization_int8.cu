/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

/*!
 * Copyright (c) 2015 by Contributors
 * \file Quantization_int8.cu
 * \brief
 * \author Jingqiu Zhou
*/

#include "./quantization_int8-inl.h"
#include<cuda.h>
#include "../common/cuda_utils.h"

#define QUANT_LEVEL 255
#define THEAD_PER_BLOCK 256
namespace mxnet {
  namespace op {
    template<typename DType>
    struct QUANT_WEIGHT_GPU{
      __device__ static void Map(int i,DType *data,DType *out,int num){
        __shared__ DType S_min[THEAD_PER_BLOCK];
        __shared__ DType S_max[THEAD_PER_BLOCK];
        __shared__ DType quant_unit;
        __shared__ DType S_min_f;
        __shared__ DType S_max_f;
        //Using reduction find the max and minx
        int current_group = THEAD_PER_BLOCK>num?num:THEAD_PER_BLOCK;
        int number_per_group = num/current_group;
        int remains = num%current_group;
        //initialize data in shared memory
        int tidx = threadIdx.x;
        if(tidx<current_group){
          S_min[tidx] = *(data+tidx*number_per_group);
          S_max[tidx] = *(data+tidx*number_per_group);
        }
        
        __syncthreads();
        //find max/min inside group
        if(tidx<(current_group-1)){
          for(int idx=0;idx<number_per_group;idx++){
            S_min[tidx] = S_min[tidx]>*(data+tidx*number_per_group+idx)?*(data+tidx*number_per_group+idx):S_min[tidx];
            S_max[tidx] = S_max[tidx]<*(data+tidx*number_per_group+idx)?*(data+tidx*number_per_group+idx):S_max[tidx];
          }
        } else if (tidx==current_group-1){
          for(int idx=0;idx<number_per_group+remains;idx++){
            S_min[tidx] = S_min[tidx]>*(data+tidx*number_per_group+idx)?*(data+tidx*number_per_group+idx):S_min[tidx];
            S_max[tidx] = S_max[tidx]<*(data+tidx*number_per_group+idx)?*(data+tidx*number_per_group+idx):S_max[tidx];
          }
        }
        __syncthreads();
        //use thread 0 to compute global max/min
        if(tidx<1){
    
          S_min_f=S_min[0];
          S_max_f=S_max[0];
          for(int idx=0;idx<current_group;idx++){
            S_min_f = S_min_f>S_min[idx]?S_min[idx]:S_min_f;
            S_max_f = S_max_f<S_max[idx]?S_max[idx]:S_max_f;
          }
          //insure 0 in the range
          if(S_min_f>DType(-1e-8)){
            S_min_f=DType(-1e-2);
          }
          if(S_max_f<DType(1e-8)){
            S_max_f=DType(1e-2);
          }
          quant_unit = (S_max_f-S_min_f)/DType(QUANT_LEVEL);
          
          DType delta = quant_unit + S_min_f/ceil(-S_min_f/quant_unit);
          //adjust range 
          quant_unit = quant_unit-delta;
          S_max_f=S_max_f-delta*DType(QUANT_LEVEL)/DType(2.);
          S_min_f=S_min_f+delta*DType(QUANT_LEVEL)/DType(2.);
     
        }

        __syncthreads();
        DType temp = *(data+i)>S_max_f?S_max_f:*(data+i);
        temp = temp<S_min_f?S_min_f:temp;
        *(out+i)=floor((temp-S_min_f)/quant_unit+0.5)*quant_unit+S_min_f;   
        
      }
    };

    template<typename DType>
    struct QUANT_ACT_GPU{
      __device__ static void Map(int i,DType *data,DType *out,DType *S_act,DType *max_S,DType *min_S,
                                 DType decay,int quant_countdown,bool init){
        DType S_max_f;
        DType S_min_f;
        DType quant_unit;
        if(init){
          S_max_f = *max_S;
          S_min_f = *min_S;
        } else {
          S_max_f = *S_act*decay+(1-decay)*(*max_S);
          S_min_f = *(S_act+1)*decay+(1-decay)*(*min_S);
        }
        if(S_max_f<1e-7){
          S_max_f=1e-2;
        }
        if(S_min_f>-1e-7){
          S_min_f=-1e-2;
        }

        if(i==0){
          *S_act = S_max_f;
          *(S_act+1) = S_min_f;
        }
        if(quant_countdown==0){
          quant_unit = (S_max_f-S_min_f)/DType(QUANT_LEVEL);
          //use i= 0 to update the recorded max/min
          DType temp = *(data+i)>S_max_f?S_max_f:*(data+i);
          temp = temp<S_min_f?S_min_f:temp;
          *(out+i)=floor((temp-S_min_f)/quant_unit+0.5)*quant_unit+S_min_f;      
        } else {
          *(out+i)=*(data+i);
        }
        
      }
    };


    template<typename DType>
    struct Launch_warper{ 
      __device__ static void Map(int i,DType *src_max,DType *dst_max,
                                DType *src_min,DType *dst_min,int current_num,int pre_num){
        //moving pinters
        int offset_ = i;
        
        bool need_compare = 2*offset_+1<=pre_num;
        //call the function
        //compute max/min every two element
        if(need_compare){
          *(dst_max+i) = *(src_max+i*2)>*(src_max+2*i+1)?*(src_max+i*2):*(src_max+i*2+1);
          *(dst_min+i) = *(src_min+i*2)<*(src_min+2*i+1)?*(src_min+i*2):*(src_min+i*2+1);
        } else {
          *(dst_max+i) = *(src_max+i*2);
          *(dst_min+i) = *(src_min+i*2);
        }
      }
    };
  }
}
namespace mshadow{
  template<typename DType>
  void quantization_int8_weight(Tensor<gpu, 3, DType> data,Tensor<gpu, 3, DType> &out,Stream<gpu> *s){
    int num = out.size(0)*out.size(1)*out.size(2);
    
    mxnet::op::mxnet_op::Kernel<mxnet::op::QUANT_WEIGHT_GPU<DType>,gpu>::Launch(s,num,
                                                                    data.dptr_,out.dptr_,
                                                                    num);
  }
  template<typename DType>
  void quantization_int8_act(Tensor<gpu, 3, DType> data,Tensor<gpu, 3, DType> &out,
                             DType *S_act,DType *Temp,
                             DType decay,Stream<gpu> *s,int quant_countdown,bool init){
    int num = out.size(0)*out.size(1)*out.size(2);
    DType *S_act_gpu;
  
    cudaMalloc((void**)&S_act_gpu,sizeof(DType)*2);
    cudaMalloc((void **)&Temp,sizeof(DType)*(num+1)/2*4);
    
    //find the max and min first
    int offset = (num+1)/2;
    int current_num = num;
    int pre_num;

    DType *src_max=data.dptr_;
    DType *src_min=data.dptr_;
    DType *dst_max=Temp;
    DType *dst_min=Temp+offset;
    DType *inter_media;
    bool first_iter = true;

    while(current_num>1){
      //after this iteration num of ele
      pre_num = current_num;
      current_num = (current_num+1)/2;
      
      mxnet::op::mxnet_op::Kernel<mxnet::op::Launch_warper<DType>,gpu>::Launch(s,current_num,
                                                                              src_max,dst_max,
                                                                              src_min,dst_min,
                                                                              current_num,pre_num);                                   
      if(first_iter){
        src_max = dst_max;
        src_min = dst_min;
        dst_max = Temp + 2*offset;
        dst_min = Temp + 3*offset;
        first_iter=false;
      } else {
        inter_media = src_max;
        src_max = dst_max;
        dst_max = inter_media;
        inter_media = src_min;
        src_min = dst_min;
        dst_min = inter_media;
      }
    }

    cudaMemcpy(S_act_gpu,S_act,sizeof(DType)*2,cudaMemcpyHostToDevice);
   
    mxnet::op::mxnet_op::Kernel<mxnet::op::QUANT_ACT_GPU<DType>,gpu>::Launch(s,num,
                                                                    data.dptr_,out.dptr_,
                                                                    S_act_gpu,src_max,src_min,
                                                                    decay,quant_countdown,init);
    cudaMemcpy(S_act,S_act_gpu,sizeof(DType)*2,cudaMemcpyDeviceToHost);
    cudaFree(Temp);
    cudaFree(S_act_gpu);
  }
}

namespace mxnet{
  namespace op{
template<>
Operator *CreateOp<gpu>(Quantization_int8Para param, int dtype) {
  Operator* op = nullptr;
  MSHADOW_REAL_TYPE_SWITCH(dtype, DType, {
    op = new Quantization_int8Op<gpu, DType>(param);
  });
  return op;
}

}  // namespace op
}  // namespace mxnet

