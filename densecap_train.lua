
--[[
Train a Dense Labeler
]]--

-------------------------------------------------------------------------------
-- Includes
-------------------------------------------------------------------------------
-- basics
--[[
require 'torch'
require 'nn'
require 'nngraph'
require 'optim'
require 'lfs'
require 'image'
-- cuda related
require 'cutorch'
require 'cunn'
require 'cudnn'
-- from others
local debugger = require('fb.debugger')
-- from us
local LSTM = require 'LSTM'
local box_utils = require 'box_utils'
local utils = require 'utils'
local voc_utils = require 'voc_utils'
local cjson = require 'cjson' -- http://www.kyne.com.au/~mark/software/lua-cjson.php
require 'vis_utils'
require 'DataLoader'
require 'optim_updates'
require 'stn_detection_model'
local eval_utils = require 'eval_utils'
--]]

require 'densecap.DataLoader'
require 'densecap.DenseCapModel'
require 'densecap.optim_updates'
local utils = require 'densecap.utils'

-------------------------------------------------------------------------------
-- Input arguments and options
-------------------------------------------------------------------------------
cmd = torch.CmdLine()
cmd:text()
cmd:text('Train a Dense Labeler')
cmd:text()
cmd:text('Options')

-- Core ConvNet settings
cmd:option('-backend', 'cudnn', 'nn|cudnn')

-- Model settings
cmd:option('-rpn_hidden_dim',512,'hidden size in the rpnnet')
cmd:option('-sampler_batch_size',256,'batch size to use in the box sampler')
cmd:option('-rnn_size',512,'size of the rnn in number of hidden nodes in each layer')
cmd:option('-input_encoding_size',512,'only used in captioning: what is the encoding size of each token in the vocabulary? (chars or words)')

-- Loss function
cmd:option('-mid_box_reg_weight',0.05,'what importance to assign to regressing bounding boxes well in rpn?')
cmd:option('-mid_objectness_weight', 0.1, 'what importance to assign to pos/neg objectness labels?')
cmd:option('-end_box_reg_weight', 0.1, 'what importance to assign to final class-specific bounding box regression?')
cmd:option('-end_objectness_weight',0.1,'what importance to assign to classifying the correct class?')
cmd:option('-captioning_weight',1.0,'what importance to assign to captioning, if present?')
cmd:option('-weight_decay', 1e-6, 'L2 weight decay penalty strength')
cmd:option('-box_reg_decay', 5e-5, 'Strength of pull for boxes towards their anchor')

-- Data input settings
cmd:option('-train_data_h5','data/vg-regions-720.h5','path to the h5file containing the preprocessed dataset')
cmd:option('-train_data_json','data/vg-regions-720-dicts.json','path to the json file containing additional info')
cmd:option('-train_frac',0.9,'fraction of data that goes into train set')
cmd:option('-val_frac',0.1,'fraction of data that goes into validation set')
cmd:option('-h5_read_all',false,'read the whole h5 dataset to memory?')
cmd:option('-debug_max_train_images', -1, 'useful for debugging: Cap #train images at this value to check that we can overfit. (-1 = disable)')
cmd:option('-proposal_regions_h5','','override RPN boxes with boxes from this h5 file (empty = don\'t override)')

-- Optimization
cmd:option('-optim','rmsprop','what update to use? rmsprop|sgd|sgdmom')
cmd:option('-cnn_optim', 'sgd', 'what update to use for CNN?')
cmd:option('-learning_rate',4e-6,'learning rate for rmsprop')
cmd:option('-optim_alpha',0.9,'alpha for rmsprop/adam/momentum')
cmd:option('-optim_beta',0.999,'for adam')
cmd:option('-optim_epsilon',1e-8,'epsilon that goes into denominator in rmsprop')
cmd:option('-finetune_cnn_after', -1, 'After what iteration do we start finetuning the CNN? (-1 = disable; never finetune, 0 = finetune from start)')
cmd:option('-checkpoint_path', 'checkpoint.t7', 'the name of the checkpoint file to use')
cmd:option('-max_iters', -1, 'max number of iterations to run for (-1 = run forever)')
cmd:option('-save_checkpoint_every', 1000, 'how often to save a model checkpoint?')
cmd:option('-val_images_use', 100, 'how many images to use when periodically evaluating the validation loss? (-1 = all)')
cmd:option('-matlab_eval_too', false, 'During validation VOC run, crease matlab evaluation intermediate files? (only used in checking our lua/torch correctness)')
cmd:option('-checkpoint_start_from', '')
cmd:option('-cnn_learning_rate',1e-4,'learning rate for the CNN')
cmd:option('-cnn_optim_alpha',0,'alpha for rmsprop/momentum for sgdmom of cnn')
cmd:option('-cnn_optim_beta', 0, 'beta for adam of cnn')

cmd:option('-train_iter_init',-1,'override dataloader iterator to this value (careful use!)')

cmd:option('-recog_dropout', 0.5, 'Probability of dropping a unit')

-- Visualization
cmd:option('-progress_dump_every', 100, 'Every how many iterations do we write a progress report to vis/out ?. 0 = disable.')
cmd:option('-losses_log_every', 10, 'How often do we save losses, for inclusion in the progress dump? (0 = disable)')

-- Training-time box sampling options
cmd:option('-sampler_high_thresh', 0.3)
cmd:option('-sampler_low_thresh', 0.7)
cmd:option('-train_remove_outbounds_boxes', 1,' Whether to ignore out-of-bounds boxes for sampling at training time')

-- misc
cmd:option('-id', '', 'an id identifying this run/job. used in cross-val and appended when writing progress files')
cmd:option('-seed', 123, 'random number generator seed to use')
cmd:option('-gpuid', 0, 'which gpu to use. -1 = use CPU')
cmd:option('-timing', false, 'whether to time parts of the net')
cmd:option('-dump_all_losses', 0)
cmd:option('-clip_final_boxes', 1,
           'whether to clip final boxes to image boundary; probably set to 0 for dense captioning')
cmd:option('-eval_objectness', 0, 'if true, evalute mAP for objectness rather than final detection')
cmd:option('-eval_first_iteration',0,'evaluate on first iteration? 1 = do, 0 = dont.')
cmd:option('-eval_outputs', 1)
cmd:option('-use_random_region_proposals', 0)

cmd:option('-cv_min_map', -1, 'if the map is lower than this during eval, the job will be killed as not going well (-1 = disable)')

cmd:text()

-------------------------------------------------------------------------------
-- Initializations
-------------------------------------------------------------------------------
local opt = cmd:parse(arg)
torch.manualSeed(opt.seed)
cutorch.manualSeed(opt.seed)
cutorch.setDevice(opt.gpuid + 1) -- note +1 because lua is 1-indexed

-- initialize the data loader class
local dataOpt = {}
dataOpt.h5_file = opt.train_data_h5
dataOpt.json_file = opt.train_data_json
dataOpt.train_frac = opt.train_frac
dataOpt.val_frac = opt.val_frac
dataOpt.h5_read_all = opt.h5_read_all
dataOpt.debug_max_train_images = opt.debug_max_train_images
dataOpt.proposal_regions_h5 = opt.proposal_regions_h5
local loader = DataLoader(dataOpt)
local seq_length = loader:getSeqLength()
local sequence_prediction = seq_length > 1 -- we will use rnn when predicting sequences
local max_image_size = loader:getImageMaxSize()
local vocab_size = loader:getVocabSize()

if opt.train_iter_init > 0 then
  loader.iterators[0] = opt.train_iter_init
  print('setting train iterator to ' .. opt.train_iter_init)
end

local model
if opt.checkpoint_start_from == '' then
  --[[
  model = StnDetectionModel{
          backend=opt.backend,
          vocab_size=vocab_size,
          sampler_batch_size=opt.sampler_batch_size,
          objectness_weight=opt.objectness_weight,
          box_reg_weight=opt.box_reg_weight,
          final_box_reg_weight=opt.final_box_reg_weight,
          classification_weight=opt.classification_weight,
          box_reg_decay=opt.box_reg_decay,
          sampler_high_thresh=opt.iou_high_thresh,
          sampler_low_thresh=opt.iou_low_thresh,
          train_remove_outbounds_boxes=opt.train_remove_outbounds_boxes,
          seq_length = seq_length,
          captioning_weight = opt.captioning_weight,
        }
  --]]
  opt.vocab_size = vocab_size
  opt.seq_length = seq_length
  model = DenseCapModel(opt, loader.info.idx_to_token)
else
  print('initializing model from ' .. opt.checkpoint_start_from)
  model = torch.load(opt.checkpoint_start_from).model
  print(model)
  model.opt.objectness_weight = opt.objectness_weight
  model.nets.detection_module.opt.obj_weight = opt.objectness_weight
  model.opt.box_reg_weight = opt.box_reg_weight
  model.nets.box_reg_crit.w = opt.final_box_reg_weight
  model.opt.classification_weight = opt.classification_weight
  local rpn = model.nets.detection_module.nets.rpn
  rpn:findModules('nn.RegularizeLayer')[1].w = opt.box_reg_decay
  model.opt.sampler_high_thresh = opt.iou_high_thresh
  model.opt.sampler_low_thresh = opt.iou_low_thresh
  model.opt.train_remove_outbounds_boxes = opt.train_remove_outbounds_boxes
  model.opt.captioning_weight = opt.captioning_weight
end

-- In either case set find Dropout modules and set their probabilities
local dropout_modules = model.nets.recog_base:findModules('nn.Dropout')
for i, dropout_module in ipairs(dropout_modules) do
  dropout_module.p = opt.recog_dropout
end

-- get the parameters vector
local params, grad_params, cnn_params, cnn_grad_params = model:getParametersSeparate{
                              with_cnn=opt.finetune_cnn_after == 0,
                              with_rpn=true,
                              with_recog_net=true}
print('total number of parameters in net: ', grad_params:nElement())
if cnn_grad_params then
  print('total number of parameters in CNN: ', cnn_grad_params:nElement())
else
  print('CNN is not being trained right now (0 parameters).')
end

if model.usernn then
  model.nets.lm_model:shareClones()
end

-------------------------------------------------------------------------------
-- Loss function
-------------------------------------------------------------------------------
local loss_history = {}
local all_losses = {}
local results_history = {}
local iter = 0
local diediedie = false
local function lossFun()
  grad_params:zero()
  if opt.finetune_cnn_after ~= -1 and iter > opt.finetune_cnn_after then
    cnn_grad_params:zero() 
  end
  model:training()

  -- Fetch data using the loader
  local timer = torch.Timer()
  local info
  local data = {}
  data.images, data.target_boxes, data.target_seqs, info, data.region_proposals = loader:getBatch()

  if opt.use_random_region_proposals == 1 then
    data.region_proposals = torch.randn(1, 10000, 5)
    data.region_proposals[{{}, {}, 1}]:mul(150):add(data.images:size(4) / 2):clamp(50, data.images:size(4) - 50)
    data.region_proposals[{{}, {}, 2}]:mul(150):add(data.images:size(3) / 2):clamp(50, data.images:size(3) - 50)
    data.region_proposals[{{}, {}, 3}]:mul(50):add(150):abs()
    data.region_proposals[{{}, {}, 4}]:mul(50):add(150):abs()
  end
  if opt.timing then cutorch.synchronize() end
  local getBatch_time = timer:time().real

  -- Run the model forward and backward
  model.timing = opt.timing
  model.cnn_backward = false
  if opt.finetune_cnn_after ~= -1 and iter > opt.finetune_cnn_after then
    model.cnn_backward = true
  end
  model.dump_vars = false
  if opt.progress_dump_every > 0 and iter % opt.progress_dump_every == 0 then
    model.dump_vars = true
  end
  local losses, stats = model:forward_backward(data)
  stats.times['getBatch'] = getBatch_time -- this is gross but ah well

  -- Apply L2 regularization
  if opt.weight_decay > 0 then
    grad_params:add(opt.weight_decay, params)
    if cnn_grad_params then cnn_grad_params:add(opt.weight_decay, cnn_params) end
  end

  if opt.dump_all_losses == 1 then
    for k, v in pairs(losses) do
      all_losses[k] = all_losses[k] or {}
      all_losses[k][iter] = v
    end
  end

  if iter % 25 == 0 then
    local boxes, scores, seq = model:forward_test(data.images)
    local txt = model:decodeSequence(seq)
    print(txt)
  end
  
  --+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
  -- Visualization/Logging code
  --+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
  if opt.losses_log_every > 0 and iter % opt.losses_log_every == 0 then
    local losses_copy = {}
    for k, v in pairs(losses) do losses_copy[k] = v end
    loss_history[iter] = losses_copy
  end

  if model.dump_vars then
    -- do a test-time forward pass
    -- this shouldn't affect our gradients for this iteration
    model:forward_test(data.images, {clip_final_boxes=opt.clip_final_boxes}, data.region_proposals)
    stats.vars.loss_history = loss_history
    if opt.dump_all_losses == 1 then
      stats.vars.all_losses = all_losses
    end
    stats.vars.results_history = results_history
    stats.vars.opt = opt
    if stats.vars.seq then
      -- use the dataloader to translate this to text
      stats.vars.seq = loader:decodeSequence(stats.vars.seq)
      stats.vars.target_cls = loader:decodeSequence(stats.vars.target_cls:transpose(1,2):contiguous())
    end
    -- snapshotProgress(stats.vars, opt.id)
  end

  return losses, stats
end

-------------------------------------------------------------------------------
-- Evaluate performance of a split
-------------------------------------------------------------------------------
local function eval_split(split, max_images)
  if max_images == nil then max_images = -1 end -- -1 = disabled
  if split == nil then split = 2 end -- 2 = val, default.
  model:evaluate()
  local out = {}

  -- TODO: we're about to reset the iterator, which means that for training data
  -- we would lose our place in the dataset as we're iterating around. 
  -- This only comes up if we ever wanted mAP on training data. Worry about later.
  assert(split == 1, 'train evaluation is tricky for now. Also test evaluation (split=2) is naughty. todo.')

  -- instantiate the evaluators
  local evaluator, evaluatorMatlab
  if not sequence_prediction then
    evaluator = VOCEvaluator(loader:getVocab(), {id = opt.id}) -- id will be appended to filenames
    if opt.matlab_eval_too then
      evaluatorMatlab = VOCEvaluatorMatlab(loader:getVocab(), { id = opt.id }) -- id will be appended to filenames
    end
  else
    evaluator = DenseCaptionEvaluator({id = opt.id})
  end
  if opt.eval_outputs == 0 then
    evaluator = nil
    evaluatorMatlab = nil
  end

  local objectness_stats = nil
  if opt.eval_objectness == 1 then
    objectness_stats = {}
  end

  loader:resetIterator(split)
  local counter = 0
  local all_losses = {}
  while true do
    counter = counter + 1

    -- fetch a batch of val data
    local data = {}
    data.images, data.target_boxes, data.target_cls, info, data.region_proposals = loader:getBatch{ split = split, iterate = true}
    local info = info[1] -- strip, since we assume only one image in batch for now

    -- evaluate the val loss function
    model.timing = false
    model.dump_vars = false
    model.cnn_backward = false

    if opt.use_random_region_proposals == 1 then
      data.region_proposals = torch.randn(1, 10000, 5)
      data.region_proposals[{{}, {}, 1}]:mul(150):add(data.images:size(4) / 2):clamp(50, data.images:size(4) - 50)
      data.region_proposals[{{}, {}, 2}]:mul(150):add(data.images:size(3) / 2):clamp(50, data.images:size(3) - 50)
      data.region_proposals[{{}, {}, 3}]:mul(50):add(150):abs()
      data.region_proposals[{{}, {}, 4}]:mul(50):add(150):abs()
    end
    local losses, stats = model:forward_backward(data)
    table.insert(all_losses, losses)

    -- if we are doing object detection also forward the model in test mode to get predictions and do mAP eval
    local boxes, logprobs, seq
    if opt.eval_objectness == 1 then
      local obj_stats = box_utils.eval_box_recall(model.rpn_boxes, data.target_boxes[1])
      table.insert(objectness_stats, obj_stats)
    end
    
    if evaluator then
      data.target_boxes = data.target_boxes[1]
      data.target_cls = data.target_cls[1]
      boxes, logprobs, seq = model:forward_test(data.images, {clip_final_boxes=opt.clip_final_boxes}, data.region_proposals)

      if sequence_prediction then
        -- captioning
        seq_text = loader:decodeSequence(seq) -- translate to text
        target_cls_text = loader:decodeSequence(data.target_cls:transpose(1,2):contiguous())
        evaluator:addResult(info, boxes, logprobs, data.target_boxes, target_cls_text, seq_text)
      else
        -- detection
        evaluator:addResult(info, boxes, logprobs, data.target_boxes, data.target_cls, seq)
      end
    end
    if evaluatorMatlab then
      evaluatorMatlab:addResult(info, boxes, logprobs, data.target_boxes, data.target_cls)
    end

    if boxes then
      print(string.format('processed image %s (%d/%d) of split %d, detected %d regions.',
        info.filename, info.split_bounds[1], math.min(max_images, info.split_bounds[2]), split, boxes:size(1)))
    else
      print(string.format('processed image %s (%d/%d) of split %d.',
        info.filename, info.split_bounds[1], math.min(max_images, info.split_bounds[2]), split))
    end

    -- we break out when we have processed the last image in the split bound
    if max_images > 0 and counter >= max_images then break end
    if info.split_bounds[1] == info.split_bounds[2] then break end
  end

  -- average validation loss across all images in validation data
  local loss_results = utils.dict_average(all_losses)
  print('Validation Loss Stats:')
  print(loss_results)
  print(string.format('validation loss: %f', loss_results.total_loss))
  out.loss_results = loss_results

  if opt.eval_objectness == 1 then
    out.objectness_results = utils.dict_average(objectness_stats)
    print(out.objectness_results)
  end

  -- print meanAP statistics in case of object detection
  if evaluator then
    local ap_results = evaluator:evaluate()
    print('Validation Average Precision Stats:')
    if ap_results.ap then -- in captioning this wont exist since only one class exists
      local idx_to_token = loader:getVocab()
      for k,v in pairs(ap_results.ap) do
        print(string.format('%d (%s): %f', k, idx_to_token[tostring(k)], 100*v))
      end
    end
    print(string.format('mAP: %f', 100*ap_results.map))
    out.ap = ap_results -- attach to output struct

    if opt.cv_min_map >= 0 and iter > 0 then
      if 100*ap_results.map < opt.cv_min_map then
        -- kill the job
        diediedie = true
      end
    end
  end

  return out
end

-------------------------------------------------------------------------------
-- Main loop
-------------------------------------------------------------------------------
local loss0
local optim_state = {}
local cnn_optim_state = {}
local best_val_score = -1
while true do  

  -- We need to rebuild params and grad_params when we start finetuning
  if iter > 0 and iter == opt.finetune_cnn_after then
    params, grad_params, cnn_params, cnn_grad_params = model:getParametersSeparate{
                            with_cnn=true,
                            with_rpn=true,
                            with_pred_net=true
                         }
    print('adding CNN to the optimization.')
    print('total number of parameters in net: ', grad_params:nElement())
    print('total number of parameters in CNN: ', cnn_params:nElement())
    if model.usernn then
      model.nets.lm_model:shareClones()
    end
  end

  -- compute the gradient
  local losses, stats = lossFun()

  -- shut off learning if we just resumed training, for the gradient cache to warm up
  local learning_rate = opt.learning_rate
  local cnn_learning_rate = opt.cnn_learning_rate
  if opt.checkpoint_start_from ~= '' and iter < 100 then
    print('KILLING LEARNING RATE!')
    learning_rate = 0
    cnn_learning_rate = 0
  end

  -- perform parameter update
  if opt.optim == 'rmsprop' then
    rmsprop(params, grad_params, learning_rate, opt.optim_alpha, opt.optim_epsilon, optim_state)
  elseif opt.optim == 'adagrad' then
    adagrad(params, grad_params, learning_rate, opt.optim_epsilon, optim_state)
  elseif opt.optim == 'sgd' then
    sgd(params, grad_params, learning_rate)
  elseif opt.optim == 'sgdm' then
    sgdm(params, grad_params, learning_rate, opt.optim_alpha, optim_state)
  elseif opt.optim == 'sgdmom' then
    sgdmom(params, grad_params, learning_rate, opt.optim_alpha, optim_state)
  elseif opt.optim == 'adam' then
    adam(params, grad_params, learning_rate, opt.optim_alpha, opt.optim_beta, opt.optim_epsilon, optim_state)
  else
    error('bad option opt.optim')
  end
  
  -- do an sgd step on cnn maybe
  if opt.finetune_cnn_after >= 0 and iter >= opt.finetune_cnn_after and cnn_learning_rate > 0 then
    if opt.cnn_optim == 'sgd' and opt.cnn_optim_alpha == 0 then
      sgd(cnn_params, cnn_grad_params, cnn_learning_rate)
    elseif opt.cnn_optim == 'sgdmom' then
      sgdmom(cnn_params, cnn_grad_params, cnn_learning_rate, opt.cnn_optim_alpha, cnn_optim_state)
    elseif opt.cnn_optim == 'sgdm' then
      sgdm(cnn_params, cnn_grad_params, cnn_learning_rate, opt.cnn_optim_alpha, cnn_optim_state)
    elseif opt.cnn_optim == 'adam' then
      adam(cnn_params, cnn_grad_params, cnn_learning_rate, opt.cnn_optim_alpha, opt.cnn_optim_beta,
           opt.optim_epsilon, cnn_optim_state)
    end
    --[[
    adam(cnn_params, cnn_grad_params, opt.cnn_learning_rate, opt.optim_beta1, opt.optim_beta2,
         opt.optim_epsilon, cnn_optim_state)
    --]]
  end

  -- print loss and timing/benchmarks
  print(string.format('iter %d: %s', iter, utils.build_loss_string(losses)))
  --print(utils.__GLOBAL_STATS__)
  if opt.timing then print(utils.build_timing_string(stats.times)) end

  if ((opt.eval_first_iteration == 1 or iter > 0) and iter % opt.save_checkpoint_every == 0) or (iter+1 == opt.max_iters) then

    -- evaluate validation performance
    local results = eval_split(1, opt.val_images_use) -- 1 = validation
    results_history[iter] = results

    -- serialize a json file that has all info except the model
    local checkpoint = {}
    checkpoint.opt = opt
    checkpoint.iter = iter
    checkpoint.loss_history = loss_history
    checkpoint.results_history = results_history
    cjson.encode_number_precision(4) -- number of sig digits to use in encoding
    cjson.encode_sparse_array(true, 2, 10)
    local text = cjson.encode(checkpoint)
    local file = io.open(opt.checkpoint_path .. '.json', 'w')
    file:write(text)
    file:close()
    print('wrote ' .. opt.checkpoint_path .. '.json')

    -- add the model and save it (only if there was improvement in map)
    local score = results.ap.map
    if score > best_val_score then
      best_val_score = score
      checkpoint.model = model
      torch.save(opt.checkpoint_path, checkpoint)
      print('wrote ' .. opt.checkpoint_path)
    end
  end
    
  -- stopping criterions
  iter = iter + 1
  if iter % 33 == 0 then collectgarbage() end -- good idea to do this once in a while
  if loss0 == nil then loss0 = losses.total_loss end
  if losses.total_loss > loss0 * 100 then
    print('loss seems to be exploding, quitting.')
    break
  end
  if opt.max_iters > 0 and iter >= opt.max_iters then break end -- stopping criterion
  if diediedie then break end -- kill signal from somewhere in the code.
end

