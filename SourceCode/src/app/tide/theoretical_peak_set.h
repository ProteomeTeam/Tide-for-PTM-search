// Benjamin Diament

// A TheoreticalPeakSet is an abstract class representing the collection of
// theoretical peaks corresponding to a peptide. Its memory is designed to be
// reusable, so it functions as a "workspace" for figuring where the
// theoretical peaks ought to be. The expected usage pattern is as follows:
//
// TheoreticalPeakSet workspace; // Some construction params may be required.
// Peptide peptide; // Assume already initialized.
// workspace.Clear(); // Memory gets reused
// For each left-substring of peptide, call workspace.AddBIon()
// For each right-substring of peptide, call workspace.AddYIon()
//
// After the B and Y ions have been added the client may retreive the
// TheoreticalPeakArr by a call to workspace.GetPeaks(). Peaks are then written
// into the provided arrays (specified in the arguments). To avoid unnecessary
// copying, for most subclasses, GetPeaks() will take the final steps necessary
// to generate the peaks and write them directly to the client-specified arrays.
// There are both "positive" peaks and "negative" peaks that may be written,
// though some subclasses will never write any negative peaks. When present,
// these negative peaks represent corrections made to the peaks in the positive
// set. This comes up in cases where the workspace in question actually
// represents a difference between two TheoreticalPeakSets. See
// TheoreticalPeakSetDiff for example.
//
// Different subclasses of TheoreticalPeakSet have varying characteristics, such
// as the following:
// 
//   o  space requirements (both in memory and on disk) 
//   o  time required to generate the peak set
//   o  sparsity (affects space requirements and dot-product time)
//   o  accuracy with respect to the "correct" value of the XCORR function.
// 
// Here are some the characteristics:
// 
//   TheoreticalPeakSetMakeAll           exact, slow, all peaks explicit
//   TheoreticalPeakSetBYSparse          inexact, fast, only B and Y explicit,
//                                       significantly larger than Diff. 
//   TheoreticalPeakSetBYSparseOrdered   same, slightly slower to generate
//   TheoreticalPeakSetBYAll             inexact but same as BYSparse, slow, 
//                                       all peaks explicit
//   TheoreticalPeakSetDiff              = MakeAll - BYAll: slow to generate,
//                                       very sparse, completely different
//                                       function from MakeAll. Gets stored at
//                                       indexing and retrieved at search time.
//   TheoreticalPeakSetSparse            For testing: very slow, explicitly
//                                       computes both Diff and BYSparse.
// 
// Let the following vectors be defined: 
//   
//   x is the vector of theoretical peaks created by MakeAll
//   y is the vector of theoretical peaks created by BYSparse
//   z is the vector of theoretical peaks created by Diff
//   w is the vector of theoretical peaks created by BYAll
//   u is the vector of observed peaks with the background subtracted.
//   v is the vector that is a linear combination of shifts of u as computed
//     in ObservedPeakSet::ComputeCache(). E.g. for charge 1 the ith element
//     of v might be (see spectrum_preprocess.h): 
//           v[i] = 50*u[i] + 25*u[i-1] + 25*u[i+1] + 10*u[i-17]
// 
// y is five times sparser than w and includes only the positions of the B and Y
// ions. BYAll and BYSparse are related as follows: <w, u> = <y, v>. The correct
// value of the XCORR is <u, x>.  But computing with MakeAll is slow.  So,
// instead we do the following: at index time we compute and store z = x - w.
// At search time we compute <y, v> + <z, u>. This incurs the cost of storing z
// but generating only y, which can be done quickly. Since both y and z are
// sparse (though z is much sparser) the above dot products can be computed
// quickly at search time.
// 
// The inexactness of BYAll (and BYSparse by extension) is due to two factors.
// First, an exact rendering of the theoretical peaks such as that in MakeAll
// would check for duplications (two peaks in the same bin). BYAll simply
// generates all B and Y peaks without checking for duplications, as this saves
// time when we generate BYSparse. The duplications get handled by Diff (the z
// vector above). Second, the peaks generated by BYAll (the w vector above)
// aren't quite correct: w is not exactly equal to x because the positions of
// the neutral loss ions at 17 and 18 Da. away may instead be at 18 and 19
// Da. away after binning.  Similarly, at charge 2, neutral loss ions may be
// either at 8 and 9 m/z away or at 9 and 10 m/z away. All these variations are
// accounted for when we subtract (x - w) to store the Diff.
// 
// TODO 253: a final descision on whether to use TheoreticalPeakSetBYSparse or
// TheoreticalPeakSetBYSparseOrdered at search time is yet to be made. Neither
// dominated the other in testing done so far.

#ifndef THEORETICAL_PEAK_SET_H
#define THEORETICAL_PEAK_SET_H

#include <iostream>
#include <algorithm>
#include "mass_constants.h"
//#include "peptide.h"
#include "peptides.pb.h"
#include "max_mz.h"
#include "theoretical_peak_pair.h"
#include "math.h"
#include <functional>

using namespace std;
typedef google::protobuf::RepeatedField<int>::const_iterator FieldIter;

class TheoreticalPeakSet {
 public:
  // Sub-classes need to support this interface (see above).
  // A do-nothing stub is provided for GetNegs().
  virtual void Clear() = 0;
  virtual void AddYIon(double mass, int charge) = 0;
  virtual void AddBIon(double mass, int charge) = 0;
  virtual void GetPeaks(TheoreticalPeakArr* peaks_charge_1,
                        TheoreticalPeakArr* negs_charge_1,
                        TheoreticalPeakArr* peaks_charge_2,
                        TheoreticalPeakArr* negs_charge_2,
                        const pb::Peptide* peptide = NULL) = 0;
  
 protected:
  ////////////////////////////////////////////////////
  // Utility functions for subclasses
  //
  // Many of these fucnctions refer to MaxMZ::Global(). At search time 
  // MaxMZ::Global() will be set at the end of the range of
  // the observed spectra so we need not calculate theoretical peaks
  // beyond this limit.
  ////////////////////////////////////////////////////

  // Copy src to dest, but for each bin copy only the highest intensity peak.
  static void RemoveDups(const TheoreticalPeakArr& src,
                         TheoreticalPeakArr* dest) {
    TheoreticalPeakArr::const_iterator i = src.begin();
    for (; i != src.end(); ++i) {
      // find last element with current index, that one being the
      // largest intensity
      int index = i->Bin();
      if (MaxBin::Global().MaxBinEnd() > 0 
          && index >= MaxBin::Global().CacheBinEnd())
        break;
      for (++i; i != src.end() && i->Bin() == index; ++i);
      --i;
      dest->push_back(*i);
    }
  }

  static void AddPeak(TheoreticalPeakArr* dest, int index,
                      TheoreticalPeakType intensity) {
    TheoreticalPeakPair peak(index, intensity);
    // must insert in nondecreasing order
    assert(dest->size() == 0 || peak.Code() >= dest->back().Code());
    dest->push_back(peak);
  }

/*  static void AddPeakUnordered(TheoreticalPeakArr* dest, int index,
                               TheoreticalPeakType intensity) {
    TheoreticalPeakPair peak(index, intensity);
    dest->push_back(peak);
  }
*/  static void AddPeakUnordered(TheoreticalPeakArr* dest, int index,
                               TheoreticalPeakType intensity, TheoreticalPeakArr* otherset) {
    TheoreticalPeakPair peak(index, intensity);
    bool found = false;
    for (TheoreticalPeakArr::iterator itr = dest->begin(); itr < dest->end(); itr++){
      if (itr->Bin() == peak.Bin()){
        found = true;
        break;
     }
    }

    for (TheoreticalPeakArr::iterator itr2 = otherset->begin(); itr2 < otherset->end(); itr2++){
      if (itr2->Bin() == peak.Bin()){
        found = true;
        break;
      }
    }
    if (!found){
      dest->push_back(peak);
    }
  }
  
  // Append src to dest.
  static void Copy(const TheoreticalPeakArr& src,
                   TheoreticalPeakArr* dest) {
    // Confirm that src is already sorted.
    assert(adjacent_find(src.begin(), src.end(), 
                         greater<TheoreticalPeakPair>()) == src.end());
    TheoreticalPeakArr::const_iterator i = src.begin();
    if (MaxBin::Global().MaxBinEnd() > 0) {
      int end = MaxBin::Global().CacheBinEnd() * NUM_PEAK_TYPES;
      for (; (i != src.end()) && (i->Code() < end); ++i)
        dest->push_back(*i);
    } else {
      for (; i != src.end(); ++i)
        dest->push_back(*i);
    }
  }

  static void CopyUnordered(const TheoreticalPeakArr& src,
                            TheoreticalPeakArr* dest) {
    TheoreticalPeakArr::const_iterator i = src.begin();
    if (MaxBin::Global().MaxBinEnd() > 0) {
      int end = MaxBin::Global().CacheBinEnd() * NUM_PEAK_TYPES;
      for (; i != src.end(); ++i) {
        if (i->Code() < end)
          dest->push_back(*i);
      }
    } else {
      for (; i != src.end(); ++i)
        dest->push_back(*i);
    }
  }

  // Compute x - y as a vector difference. Store positive peaks in pos, 
  // negative peaks in neg. TODO 262: can simply be expressed as symmetric set
  // difference between x and y.
  static void Diff(const TheoreticalPeakArr& x,
                   const TheoreticalPeakArr& y,
                   TheoreticalPeakArr* pos,
                   TheoreticalPeakArr* neg) {
    TheoreticalPeakArr::const_iterator x_iter = x.begin();
    TheoreticalPeakArr::const_iterator y_iter = y.begin();
    while (x_iter != x.end() && y_iter != y.end()) {
      if (*x_iter < *y_iter) {
        pos->push_back(*x_iter++);
      } else if (*y_iter < *x_iter) {
        neg->push_back(*y_iter++);
      } else {
        // if equal, they cancel; push nothing!
        x_iter++; y_iter++;
      }
    }
    for (; x_iter != x.end(); ++x_iter)
      pos->push_back(*x_iter);
    for (; y_iter != y.end(); ++y_iter)
      neg->push_back(*y_iter);
  }

  // Copy from peaks from protocol buffer to dest. 
  static void CopyExceptions(const google::protobuf::RepeatedField<int>& src,
                             TheoreticalPeakArr* dest) {
    // dest may be unordered!
    // The protocol buffer stores deltas between peak values, so we need
    // to track the total:
    int total = 0;
    int end = MaxBin::Global().CacheBinEnd() * NUM_PEAK_TYPES;
    FieldIter i = src.begin();
    for (; i != src.end(); ++i) {
      if ((total += *i) >= end)
        break;
      dest->push_back(TheoreticalPeakPair(total));
    }
  }
};

// Utility class for use by subclasses of TheoreticalPeakSet. Contains the
// actual arrays of B series and Y series ions. The temp[123]_ arrays are
// spaces for merging sorted arrays of B and Y ions. This class also manages
// merges with peaks taken from Peptide protocol buffers.
class OrderedPeakSets {
 public:
  void Init(int capacity) {
    b_series_[0].Init(capacity);
    b_series_[1].Init(capacity);
    y_series_[0].Init(capacity);
    y_series_[1].Init(capacity);
    temp1_.Init(capacity);
    temp2_.Init(capacity);
    temp3_.Init(capacity);
  }

  void Clear() {
    b_series_[0].clear();
    b_series_[1].clear();
    y_series_[0].clear();
    y_series_[1].clear();
  }

  // temp1_ gets the charge 1 peaks. temp3_ gets the combined charge 1 and
  // charge 2 peaks.
  void Merge(const pb::Peptide* peptide = NULL) {
    if (peptide && peptide->peak1_size() > 0) {
      MergePeaks(&b_series_[0], &y_series_[0], &temp3_);
      MergeExceptions(temp3_, peptide->peak1(), &temp1_);
    } else {
      MergePeaks(&b_series_[0], &y_series_[0], &temp1_);
    }
    if (peptide && peptide->peak2_size() > 0) {
      MergePeaks(&b_series_[1], &y_series_[1], &temp3_);
      MergeExceptions(temp3_, peptide->peak2(), &temp2_);
    } else {
      MergePeaks(&b_series_[1], &y_series_[1], &temp2_);
    }
    MergePeaks(&temp1_, &temp2_, &temp3_);
  }

  TheoreticalPeakArr b_series_[2];
  TheoreticalPeakArr y_series_[2];
  TheoreticalPeakArr temp1_, temp2_, temp3_;

 private:
  static void MergePeaks(TheoreticalPeakArr* a, TheoreticalPeakArr* b,
                         TheoreticalPeakArr* result) {
    merge(a->begin(), a->end(), b->begin(), b->end(), result->data());
    result->set_size(a->size() + b->size());
  }

  static void MergeExceptions(const TheoreticalPeakArr& src,
                              const google::protobuf::RepeatedField<int>& exc,
                              TheoreticalPeakArr* dest) {
    dest->clear();
    // The protocol buffer stores deltas between peak values, so we need
    // to track the total:
    int total = 0;
    int end = MaxBin::Global().CacheBinEnd() * NUM_PEAK_TYPES;
    FieldIter exc_iter = exc.begin();
    TheoreticalPeakArr::const_iterator src_iter = src.begin();

    if ((exc_iter != exc.end()) && (src_iter != src.end())
        && ((total = *exc_iter) < end) && (src_iter->Code() < end)) {
      while (true) {
        bool advance_src = total >= src_iter->Code();
        bool advance_exc = total <= src_iter->Code();
        if (advance_src) {
          dest->push_back(*src_iter++);
          if (src_iter == src.end() || (src_iter->Code() >= end))
            break;
        }
        if (advance_exc) {
          dest->push_back(TheoreticalPeakPair(total));
          total += *(++exc_iter);
          if (exc_iter == exc.end() || (total >= end))
            break;
        }        
      }
    }

    if (total < end) {
      for (; exc_iter != exc.end(); ++exc_iter) {
        if ((total += *exc_iter) >= end)
          break;
        dest->push_back(TheoreticalPeakPair(total));
      }
    }
    for (; src_iter != src.end() && src_iter->Code() < end; ++src_iter) {
      dest->push_back(*src_iter);
    }
#ifdef DEBUG
    // The last assert here is expensive, so we relegate use to DEBUG mode.
    assert(exc_iter == exc.end() || total >= end);
    assert(src_iter == src.end() || src_iter->Code() >= end);
    assert(dest->size() == (exc_iter - exc.begin()) + (src_iter - src.begin()));
    assert(adjacent_find(dest->begin(), dest->end(), 
           greater<TheoreticalPeakPair>()) == dest->end());
#endif
  }
};

#if 0
DECLARE_bool(flanks);
DECLARE_bool(dups_ok);
#endif

// Subclass of TheoreticalPeakSet that generates all ions individually and
// explicitly.  The peaks generated will all have type LossPeak, FlankingPeak, or
// PrimaryPeak. 
/*class TheoreticalPeakSetMakeAll : public TheoreticalPeakSet {
 public:
  TheoreticalPeakSetMakeAll(int capacity) {
    ordered_peak_sets_.Init(capacity);
  }

  virtual ~TheoreticalPeakSetMakeAll() {}

  void Clear() { ordered_peak_sets_.Clear(); }

  void AddYIon(double mass, int charge) {
    assert(charge <= 2);
    AddYIon(mass, charge, &ordered_peak_sets_.y_series_[charge-1]);
  }

  void AddBIon(double mass, int charge) {
    assert(charge <= 2);
    AddBIon(mass, charge, &ordered_peak_sets_.b_series_[charge-1]);
  }

  void GetPeaks(TheoreticalPeakArr* peaks_charge_1,
		TheoreticalPeakArr* negs_charge_1,
		TheoreticalPeakArr* peaks_charge_2,
		TheoreticalPeakArr* negs_charge_2,
		const pb::Peptide* peptide = NULL) {
    assert(peptide == NULL);
    ordered_peak_sets_.Merge();
    if (false ) {
      CopyUnordered(ordered_peak_sets_.temp1_, peaks_charge_1);
      CopyUnordered(ordered_peak_sets_.temp3_, peaks_charge_2);
    } else {
      RemoveDups(ordered_peak_sets_.temp1_, peaks_charge_1);
      RemoveDups(ordered_peak_sets_.temp3_, peaks_charge_2);
    }
    // no negs
  }

 private:
  void AddYIon(double mass, int charge, TheoreticalPeakArr* dest) {
    // H2O
    int index = MassConstants::mass2bin(mass + MassConstants::Y_H2O, charge);
    AddPeak(dest, index, LossPeak);
    // NH3
    index = MassConstants::mass2bin(mass + MassConstants::Y_NH3, charge);
    AddPeak(dest, index, LossPeak);
    index = MassConstants::mass2bin(mass + MassConstants::Y, charge);

    if (true ) AddPeak(dest, index-1, FlankingPeak);
    AddPeak(dest, index, PrimaryPeak);
    if (true ) AddPeak(dest, index+1, FlankingPeak);
  }

  void AddBIon(double mass, int charge, TheoreticalPeakArr* dest) {
    // A-Ion
    int index = MassConstants::mass2bin(mass + MassConstants::A, charge);

    AddPeak(dest, index, LossPeak);
    // H2O
    index = MassConstants::mass2bin(mass + MassConstants::B_H2O, charge);
    AddPeak(dest, index, LossPeak);
    // Rest of peaks are as for Y ion
    // NH3
    index = MassConstants::mass2bin(mass + MassConstants::B_NH3, charge);
    AddPeak(dest, index, LossPeak);
    index = MassConstants::mass2bin(mass + MassConstants::B, charge);

    if (true ) AddPeak(dest, index-1, FlankingPeak);
    AddPeak(dest, index, PrimaryPeak);
    if (true) AddPeak(dest, index+1, FlankingPeak);
  }

  OrderedPeakSets ordered_peak_sets_;
};
*/
// A subclass of TheoreticalPeakSet that generates a theoretical peak
// for each B and Y ion at each charge state, 1 and 2. Peak generated
// will be of type PeakCombinedB1 and PeakCombinedY1 for charge 1
// ions. Peaks of type PeakCombinedB2a or PeakCombinedB2b will be
// generated for each B ion of charge 2 depending on whether the
// corresponding ammonia loss is 8 bins or 9 bins away. Similarly,
// peaks of type PeakCombinedY2a or PeakCombinedY2b will be generated
// for each Y ion of charge 2.
class TheoreticalPeakSetBYSparse : public TheoreticalPeakSet {
 public:
  explicit TheoreticalPeakSetBYSparse(int capacity) {
    peaks_[0].Init(capacity);
    peaks_[1].Init(capacity);
  }

  virtual ~TheoreticalPeakSetBYSparse() {}

  void Clear() {
    peaks_[0].clear();
    peaks_[1].clear();
  }

  void AddYIon(double mass, int charge) {
     assert(charge <= 2);
    int index_y = MassConstants::mass2bin(mass + MassConstants::Y + MassConstants::proton, charge);
//    cout << "index_y:  " << index_y << endl;
    TheoreticalPeakType series;
    if (charge == 1) {
      series = PeakCombinedY1;
    } else {
//    int nh3_diff = index_y - MassConstants::mass2bin(mass + MassConstants::Y_NH3, charge);
//      assert(nh3_diff == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_A ||
//             nh3_diff == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_B);
//      series = nh3_diff == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_A ? PeakCombinedY2a 
//                                                      : PeakCombinedY2b;
      series = PeakCombinedY2;
    }
//    AddPeakUnordered(&peaks_[charge-1], index_y, series);
    if (charge == 1)
      AddPeakUnordered(&peaks_[charge-1], index_y, series, &peaks_[charge]);
    else
      AddPeakUnordered(&peaks_[charge-1], index_y, series, &peaks_[charge-2]);
  }

  void AddBIon(double mass, int charge) {
     assert(charge <= 2);
    int index_b = MassConstants::mass2bin(mass + MassConstants::B + MassConstants::proton, charge);
//    cout << "index_b:  " << index_b << endl;
    TheoreticalPeakType series;
    if (charge == 1) {
      series = PeakCombinedB1;
    } else {
//      int nh3_diff = index_b - MassConstants::mass2bin(mass + MassConstants::B_NH3, charge);
//      assert(nh3_diff == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_A ||
//             nh3_diff == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_B);
//      series = nh3_diff == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_A ? PeakCombinedB2a 
//                                                      : PeakCombinedB2b;
      series = PeakCombinedB2;

    }
//    AddPeakUnordered(&peaks_[charge-1], index_b, series);
    if (charge == 1)
      AddPeakUnordered(&peaks_[charge-1], index_b, series, &peaks_[charge]);
    else 
      AddPeakUnordered(&peaks_[charge-1], index_b, series, &peaks_[charge-2]);
  }

  // Faster interface needing no copying at all.
  const TheoreticalPeakArr* GetPeaks() const { return peaks_; }

  void GetPeaks(TheoreticalPeakArr* peaks_charge_1,
    TheoreticalPeakArr* negs_charge_1,
    TheoreticalPeakArr* peaks_charge_2,
    TheoreticalPeakArr* negs_charge_2,
    const pb::Peptide* peptide = NULL) {
//    CopyUniqueUnordered(peaks_[0], peaks_charge_1);
//    CopyUniqueUnordered(peaks_[0], peaks_charge_2);
//    CopyUniqueUnordered(peaks_[1], peaks_charge_2);
    CopyUnordered(peaks_[0], peaks_charge_1);
    CopyUnordered(peaks_[0], peaks_charge_2);
    CopyUnordered(peaks_[1], peaks_charge_2);
    if (peptide == NULL)
      return;
    CopyExceptions(peptide->peak1(), peaks_charge_1);
    CopyExceptions(peptide->peak2(), peaks_charge_2);
    CopyExceptions(peptide->neg_peak1(), negs_charge_1);
    CopyExceptions(peptide->neg_peak2(), negs_charge_2);    
  }

 private:
  TheoreticalPeakArr peaks_[2];
};

// Subclass of TheoreticalPeakSet similar to TheoreticalPeakSetBYSparse 
// (above), but guarantees that peaks will be in increasing order by m/z
// at the expense of a couple of extra merge operations.
/*class TheoreticalPeakSetBYSparseOrdered : public TheoreticalPeakSet {
 public:
  TheoreticalPeakSetBYSparseOrdered(int capacity) {
    ordered_peak_sets_.Init(capacity);
  }

  virtual ~TheoreticalPeakSetBYSparseOrdered() {}

  void Clear() { ordered_peak_sets_.Clear(); }

  void AddYIon(double mass, int charge) {
    assert(charge <= 2);
    int index_y = MassConstants::mass2bin(mass + MassConstants::Y, charge);
    TheoreticalPeakType series;
    if (charge == 1) {
      series = PeakCombinedY1;
    } else {
      int nh3_diff = index_y - MassConstants::mass2bin(mass + MassConstants::Y_NH3, charge);
      assert(nh3_diff == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_A ||
             nh3_diff == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_B);
      series = nh3_diff == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_A ? PeakCombinedY2a 
                                                      : PeakCombinedY2b;
    }
    AddPeak(&ordered_peak_sets_.y_series_[charge-1], index_y, series);
  }

  void AddBIon(double mass, int charge) {
    assert(charge <= 2);
    int index_b = MassConstants::mass2bin(mass + MassConstants::B, charge);
    TheoreticalPeakType series;
    if (charge == 1) {
      series = PeakCombinedB1;
    } else {
      int nh3_diff = index_b - MassConstants::mass2bin(mass + MassConstants::B_NH3, charge);
      assert(nh3_diff == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_A ||
             nh3_diff == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_B);
      series = nh3_diff == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_A ? PeakCombinedB2a 
                                                      : PeakCombinedB2b;
    }
    AddPeak(&ordered_peak_sets_.b_series_[charge-1], index_b, series);
  }


  void GetPeaks(TheoreticalPeakArr* peaks_charge_1,
    TheoreticalPeakArr* negs_charge_1,
    TheoreticalPeakArr* peaks_charge_2,
		TheoreticalPeakArr* negs_charge_2,
		const pb::Peptide* peptide = NULL) {
    ordered_peak_sets_.Merge(peptide);
    Copy(ordered_peak_sets_.temp1_, peaks_charge_1);
    Copy(ordered_peak_sets_.temp3_, peaks_charge_2);
    if (peptide == NULL)
      return;
    CopyExceptions(peptide->neg_peak1(), negs_charge_1);
    CopyExceptions(peptide->neg_peak2(), negs_charge_2);    
  }

 private:
  OrderedPeakSets ordered_peak_sets_;
};

// Subclass of TheoreticalPeakSet. This class explicitly generates all ions 
// implicit in the TheoreticalPeakTypes PeakCombinedXXX. See notes above.
class TheoreticalPeakSetBYAll : public TheoreticalPeakSet {
 public:
  TheoreticalPeakSetBYAll(int capacity) {
    ordered_peak_sets_.Init(capacity);
  }

  virtual ~TheoreticalPeakSetBYAll() {}

  void Clear() { ordered_peak_sets_.Clear(); }

  void AddYIon(double mass, int charge) {
    assert(charge <= 2);
    AddYIon(mass, charge, &ordered_peak_sets_.y_series_[charge-1]);
  }

  void AddBIon(double mass, int charge) {
    assert(charge <= 2);
    AddBIon(mass, charge, &ordered_peak_sets_.b_series_[charge-1]);
  }

  void GetPeaks(TheoreticalPeakArr* peaks_charge_1,
    TheoreticalPeakArr* negs_charge_1,
    TheoreticalPeakArr* peaks_charge_2,
    TheoreticalPeakArr* negs_charge_2,
    const pb::Peptide* peptide = NULL) {
    assert(peptide == NULL);
    ordered_peak_sets_.Merge();
    Copy(ordered_peak_sets_.temp1_, peaks_charge_1);
    Copy(ordered_peak_sets_.temp3_, peaks_charge_2);
  }

 private:
  void AddYIon(double mass, int charge, TheoreticalPeakArr* dest) {
    int index_y = MassConstants::mass2bin(mass + MassConstants::Y, charge);
    if (charge == 1) {
      AddPeak(dest, index_y - MassConstants::BIN_SHIFT_H2O_CHG_1, LossPeak);
      AddPeak(dest, index_y - MassConstants::BIN_SHIFT_NH3_CHG_1, LossPeak);
    } else {
      AddPeak(dest, index_y - MassConstants::BIN_SHIFT_H2O_CHG_2, LossPeak);
      // In case A the NH3 peak will have been added already...
      assert(MassConstants::BIN_SHIFT_H2O_CHG_2 == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_A);
      // Otherwise (case B), a separate NH3 peak is needed. 
      if (index_y - MassConstants::mass2bin(mass + MassConstants::Y_NH3, charge) 
          == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_B)
        AddPeak(dest, index_y - MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_B, LossPeak);
    }
    AddPeak(dest, index_y-1, FlankingPeak);
    AddPeak(dest, index_y, PrimaryPeak);
    AddPeak(dest, index_y+1, FlankingPeak);
  }

  void AddBIon(double mass, int charge, TheoreticalPeakArr* dest) {
    int index_b = MassConstants::mass2bin(mass + MassConstants::B, charge);
    if (charge == 1) {
      AddPeak(dest, index_b - MassConstants::BIN_SHIFT_A_ION_CHG_1, LossPeak);
      AddPeak(dest, index_b - MassConstants::BIN_SHIFT_H2O_CHG_1, LossPeak);
      AddPeak(dest, index_b - MassConstants::BIN_SHIFT_NH3_CHG_1, LossPeak);
    } else {
      AddPeak(dest, index_b - MassConstants::BIN_SHIFT_A_ION_CHG_2, LossPeak);
      AddPeak(dest, index_b - MassConstants::BIN_SHIFT_H2O_CHG_2, LossPeak);
      // In case A the NH3 peak will have been added already...
      assert(MassConstants::BIN_SHIFT_H2O_CHG_2 == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_A);
      // Otherwise (case B), a separate NH3 peak is needed. 
	  if (index_b - MassConstants::mass2bin(mass + MassConstants::B_NH3, charge) 
          == MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_B)
        AddPeak(dest, index_b - MassConstants::BIN_SHIFT_NH3_CHG_2_CASE_B, LossPeak);
    }
    AddPeak(dest, index_b-1, FlankingPeak);
    AddPeak(dest, index_b, PrimaryPeak);
    AddPeak(dest, index_b+1, FlankingPeak);
  }

  OrderedPeakSets ordered_peak_sets_;
};

// Subclass of TheoreticalPeakSet. This class effectively computes 
// the vecotor difference of TheoreticalPeakSetMakeAll and 
// TheoreticalPeakSetBYAll.
class TheoreticalPeakSetDiff : public TheoreticalPeakSet {
 public:
  TheoreticalPeakSetDiff(int capacity)
    : BY_all_(capacity), make_all_(capacity),
    make_all_1_(capacity), make_all_2_(capacity),
    BY_all_1_(capacity), BY_all_2_(capacity) {
  }

  virtual ~TheoreticalPeakSetDiff() {}

  void Clear() {
    BY_all_.Clear();
    make_all_.Clear();

    make_all_1_.clear();
    make_all_2_.clear();
    BY_all_1_.clear();
    BY_all_2_.clear();
  }

  void AddYIon(double mass, int charge) {
    BY_all_.AddYIon(mass, charge);
    make_all_.AddYIon(mass, charge);
  }

  void AddBIon(double mass, int charge) {
    BY_all_.AddBIon(mass, charge);
    make_all_.AddBIon(mass, charge);
  }

  void GetPeaks(TheoreticalPeakArr* peaks_charge_1,
		TheoreticalPeakArr* negs_charge_1,
		TheoreticalPeakArr* peaks_charge_2,
		TheoreticalPeakArr* negs_charge_2,
		const pb::Peptide* peptide = NULL) {
    assert(peptide == NULL);

    make_all_.GetPeaks(&make_all_1_, NULL, &make_all_2_, NULL);
    BY_all_.GetPeaks(&BY_all_1_, NULL, &BY_all_2_, NULL);
    
    Diff(make_all_1_, BY_all_1_, peaks_charge_1, negs_charge_1);
    Diff(make_all_2_, BY_all_2_, peaks_charge_2, negs_charge_2);
  }

 private:
  TheoreticalPeakSetBYAll BY_all_;
  TheoreticalPeakSetMakeAll make_all_;

  // space for partial results, used by GetPeaks() above.
  TheoreticalPeakArr make_all_1_;
  TheoreticalPeakArr make_all_2_;
  TheoreticalPeakArr BY_all_1_;
  TheoreticalPeakArr BY_all_2_;
};

// For testing. Bypasses disk storage, doing the combined operations done at
// indexing and search time. Explicitly represents BYSparse and Diff.
class TheoreticalPeakSetSparse : public TheoreticalPeakSet {
 public:
  TheoreticalPeakSetSparse(int capacity)
    : BY_sparse_(capacity), diff_(capacity) {
  }

  virtual ~TheoreticalPeakSetSparse() {}

  void Clear() {
    BY_sparse_.Clear();
    diff_.Clear();
  }

  void AddYIon(double mass, int charge) {
    BY_sparse_.AddYIon(mass, charge);
    diff_.AddYIon(mass, charge);
  }

  void AddBIon(double mass, int charge) {
    BY_sparse_.AddBIon(mass, charge);
    diff_.AddBIon(mass, charge);
  }

  void GetPeaks(TheoreticalPeakArr* peaks_charge_1,
                TheoreticalPeakArr* negs_charge_1,
                TheoreticalPeakArr* peaks_charge_2,
                TheoreticalPeakArr* negs_charge_2,
                const pb::Peptide* peptide = NULL) {
    assert(peptide == NULL);
    BY_sparse_.GetPeaks(peaks_charge_1, NULL, peaks_charge_2, NULL);
    diff_.GetPeaks(peaks_charge_1, negs_charge_1,
                   peaks_charge_2, negs_charge_2);
  }

 private:
  TheoreticalPeakSetBYSparse BY_sparse_;
  TheoreticalPeakSetDiff diff_;
};

*/

// This class is used to store theoretical b ions only, with true monoisotopic mass,
// for use in exact p-value calculations.
class TheoreticalPeakSetBIons {
 public:
  TheoreticalPeakSetBIons() {}
  explicit TheoreticalPeakSetBIons(int capacity) {
    unordered_peak_list_.reserve(capacity);
  }
  virtual ~TheoreticalPeakSetBIons() {}

  void Clear() { unordered_peak_list_.clear(); }
  void AddBIon(double mass) {
    unsigned int index = (unsigned int)floor(mass / binWidth_ + 1.0 - binOffset_);
    unordered_peak_list_.push_back(index);
  }
  vector<unsigned int> unordered_peak_list_;
  double binWidth_;
  double binOffset_;
};
#endif // THEORETICAL_PEAK_SET_H
