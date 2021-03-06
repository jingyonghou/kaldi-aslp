#!/usr/bin/bash

# Created on 2018-01-22
# Author: Binbin Zhang
[ -f cmd.sh ] && . ./cmd.sh;
[ -f path.sh ] && . ./path.sh; 
. parse_options.sh || exit 1;

stage=3
cmd=run.pl
nj=10
num_cv_utt=1000
feat_dir=fbank

other_ali=exp/tri3a_ali
kws_ali=exp/tri3a_kws_ali
ali=exp/tri3a_merge_ali

kws_data=data/kws
train_merge_data=data/kws/train_kws
test_merge_data=data/kws/test_kws
dir=exp/kws_dnn256_xiaogua

# Align kws data
if [ $stage -le 0 ]; then
    echo "yes"
    mfccdir=mfcc
    steps/make_mfcc_pitch.sh --cmd "$train_cmd" --nj 10 $kws_data exp/make_mfcc/kws $mfccdir || exit 1;
    steps/compute_cmvn_stats.sh $kws_data exp/make_mfcc/kws $mfccdir || exit 1;
    utils/fix_data_dir.sh $kws_data || exit 1;
    
    steps/align_fmllr.sh --cmd "$train_cmd" --nj 10 \
      data/kws data/lang exp/tri3a exp/tri3a_kws_ali || exit 1;
fi

# Merge kws alignment and training data alignment
if [ $stage -le 1 ]; then
    mkdir -p $train_merge_data $test_merge_data
    cat data/train/wav.scp $kws_data/train/wav.scp | sort > $train_merge_data/wav.scp      
    cat data/train/text $kws_data/train/text | sort > $train_merge_data/text
    cat data/train/spk2utt $kws_data/train/spk2utt | sort > $train_merge_data/spk2utt
    cat data/train/utt2spk $kws_data/train/utt2spk | sort > $train_merge_data/utt2spk
    
    cat data/test/wav.scp $kws_data/test/wav.scp | sort > $test_merge_data/wav.scp      
    cat data/test/text $kws_data/test/text | sort > $test_merge_data/text
    cat data/test/spk2utt $kws_data/test/spk2utt | sort > $test_merge_data/spk2utt
    cat data/test/utt2spk $kws_data/test/utt2spk | sort > $test_merge_data/utt2spk
    cat data/test/wav.scp | awk '{print $1, 0}' > $test_merge_data/negative
    cat $kws_data/test/wav.scp | awk '{print $1, 1}' > $test_merge_data/positive
    cat $test_merge_data/negative $test_merge_data/positive | sort > $test_merge_data/label

    mkdir -p $ali
    cp $other_ali/final.mdl $ali
    cp $other_ali/tree $ali
    cur=1
    for x in $other_ali/ali.*.gz; do
        cp $x $ali/ali.${cur}.gz
        cur=$[$cur+1]
    done
    for x in $kws_ali/ali.*.gz; do
        cp $x $ali/ali.${cur}.gz
        cur=$[$cur+1]
    done
fi

## Prepare feat feat_type: mfcc
if [ $stage -le 2 ]; then 
    echo "Extracting feats & Create tr cv set"
    [ ! -d $feat_dir] && mkdir -p $feat_dir
    cp -r $train_merge_data $feat_dir/train
    cp -r $test_merge_data $feat_dir/test
    steps/make_fbank.sh --fbank-config conf/fbank.conf --nj $nj $feat_dir/train $feat_dir/log $feat_dir/feat
    steps/make_fbank.sh --fbank-config conf/fbank.conf --nj $nj $feat_dir/test $feat_dir/log $feat_dir/feat
    compute-cmvn-stats --binary=false scp:$feat_dir/train/feats.scp $feat_dir/train/global_cmvn
    ## Split tr & cv
    utils/shuffle_list.pl $feat_dir/train/feats.scp | tail -n $num_cv_utt > $feat_dir/train/cv.scp
    utils/filter_scp.pl --exclude $feat_dir/train/cv.scp $feat_dir/train/feats.scp | sort > $feat_dir/train/tr.scp 

    utils/subset_data_dir.sh --utt-list $feat_dir/train/tr.scp \
        $feat_dir/train $feat_dir/train_tr
    utils/subset_data_dir.sh --utt-list $feat_dir/train/cv.scp \
        $feat_dir/train $feat_dir/train_cv
fi

if [ $stage -le 3 ]; then 
    [ ! -d $dir ] && mkdir -p $dir;
    echo "Prepare keyword phone & id"
    echo "你好小瓜 n i3 h ao3 x iao3 g ua1" > $dir/hotword.lexicon
    echo "Hello小瓜 h a1 l ou2 x iao3 g ua1" >> $dir/hotword.lexicon
    echo "<eps> 0" > $dir/hotword.int
    echo "你好小瓜 1" >> $dir/hotword.int
    echo "Hello小瓜 2" >> $dir/hotword.int
    echo "sil" > $dir/hotword.phone
    cat $dir/hotword.lexicon | awk '{ for(i=2; i<=NF; i++) print $i; }' | sort | uniq >> $dir/hotword.phone
    echo "<eps> 0" > $dir/hotword.phone.int
    echo "<gbg> 1" >> $dir/hotword.phone.int
    cat $dir/hotword.phone | awk '{print $1, NR+1}' >> $dir/hotword.phone.int
    echo "sil" > $dir/hotword.filler
    echo "<eps>" >> $dir/hotword.filler
    echo "<gbg>" >> $dir/hotword.filler
    utils/filter_scp.pl $dir/hotword.filler $dir/hotword.phone.int > $dir/hotword.filler.int
    awk -v hotword_phone=$dir/hotword.phone.int \
    'BEGIN {
        while (getline < hotword_phone) {
            map[$1] = $2 - 1
        }
    }
    {
        if(!match($1, "#") && !match($1, "<")) { 
            printf("%s %s\n", $2, map[$1] != "" ? map[$1] : 0)
        }
    }
    ' data/lang/phones.txt > $dir/phone.map
fi

if [ $stage -le 4 ]; then
    echo "python aslp_scripts/kws/gen_text_fst.py $dir/hotword.lexicon $dir/hotword.text.fst"
    python aslp_scripts/kws/gen_text_fst.py $dir/hotword.lexicon $dir/hotword.text.openfst 
    fstcompile --isymbols=$dir/hotword.phone.int --osymbols=$dir/hotword.int $dir/hotword.text.openfst | \
        fstdeterminize | fstminimizeencoded > $dir/hotword.openfst 
    fstdraw --isymbols=$dir/hotword.phone.int --osymbols=$dir/hotword.int $dir/hotword.openfst $dir/hotword.openfst.dot
    fstprint --isymbols=$dir/hotword.phone.int --osymbols=$dir/hotword.int $dir/hotword.openfst $dir/hotword.text.min.openfst
    aslp-fst-init --isymbols=$dir/hotword.phone.int --osymbols=$dir/hotword.int $dir/hotword.text.min.openfst $dir/hotword.fst
    aslp-fst-to-dot --isymbols=$dir/hotword.phone.int --osymbols=$dir/hotword.int $dir/hotword.fst > $dir/hotword.fst.dot
fi

if [ $stage -le 5 ]; then
    echo "Preparing alignment and feats"
    aslp_scripts/kws/prepare_feats_ali.sh \
        --global_cmvn_file $feat_dir/train/global_cmvn \
        --cmvn_opts "--norm-means=true --norm-vars=true" \
        --splice_opts "--left-context=5 --right-context=5" \
        --phone_map_file $dir/phone.map \
        $feat_dir/train_tr $feat_dir/train_cv $feat_dir/test data/lang $ali $ali $dir || exit 1;
    cp $feat_dir/test/label $dir/test.label
fi

# Get feats_tr feats_cv labels_tr labels_cv 
[ ! -f $dir/train.conf ] && \
    echo "$dir/train.conf(config file for nn training): no such file" && exit 1 
source $dir/train.conf

# Prepare lstm init nnet
if [ $stage -le 6 ]; then
    echo "Pretraining nnet"
    num_feat=$(feat-to-dim "$feats_tr" -) 
    num_phones=`cat $dir/hotword.phone | wc -l`
    num_tgt=$[$num_phones+1] # add filler 
    hid_dim=256
    echo $num_feat $num_tgt

# Init nnet.proto with 2 lstm layers
cat > $dir/nnet.proto <<EOF
<NnetProto>
<AffineTransform> <InputDim> $num_feat <OutputDim> $hid_dim <BiasMean> -2.000000 <BiasRange> 4.000000 <ParamStddev> 0.1
<ReLU> <InputDim> $hid_dim <OutputDim> $hid_dim
<AffineTransform> <InputDim> $hid_dim <OutputDim> $hid_dim <BiasMean> -2.000000 <BiasRange> 4.000000 <ParamStddev> 0.1
<ReLU> <InputDim> $hid_dim <OutputDim> $hid_dim
<AffineTransform> <InputDim> $hid_dim <OutputDim> $hid_dim <BiasMean> -2.000000 <BiasRange> 4.000000 <ParamStddev> 0.1
<ReLU> <InputDim> $hid_dim <OutputDim> $hid_dim
<AffineTransform> <InputDim> $hid_dim <OutputDim> $num_tgt <BiasMean> -2.000000 <BiasRange> 4.000000 <ParamStddev> 0.1
<Softmax> <InputDim> $num_tgt <OutputDim> $num_tgt
</NnetProto>
EOF

fi

# Train nnet(dnn, cnn, lstm)
if [ $stage -le 7 ]; then
    echo "Training nnet"
    nnet_init=$dir/nnet/train.nnet.init
    aslp-nnet-init $dir/nnet.proto $nnet_init
    #"$train_cmd" $dir/log/train.log \
    aslp_scripts/aslp_nnet/train_scheduler.sh --train-tool "aslp-nnet-train-frame" \
        --learn-rate 0.0001 \
        --momentum 0.9 \
        --min-iters 5 \
        --max-iters 50 \
        --keep-lr-iters 3 \
        --l2-penalty 1e-5 \
        --minibatch_size 256 \
        --train-tool-opts "" \
        $nnet_init "$feats_tr" "$feats_cv" "$labels_tr" "$labels_cv" $dir
fi

if [ $stage -le 8 ]; then
    [ ! -e $dir/final.nnet ] && echo "$dir/final.nnet: no such file" && exit 1;
    aslp-kws-score --verbose=1 $dir/final.nnet $dir/hotword.fst $dir/hotword.filler.int \
        "$feats_test" "ark,t:$dir/confidence.ark" "ark,t:$dir/id.ark" &> $dir/score.log 
    #python aslp_scripts/kws/evaluation_roc.py $dir/confidence.ark $dir/test.label > $dir/test.result
    #cat $dir/test.result | awk '{printf("%s\t%s\n", $8, $6)}' > $dir/test.roc 
fi
