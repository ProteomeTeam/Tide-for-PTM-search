#include <cstdio>
#include "app/tide/abspath.h"
#include "app/tide/records_to_vector-inl.h"

#include "io/carp.h"
#include "parameter.h"
#include "io/SpectrumRecordWriter.h"
#include "TideIndexApplication.h"
#include "TideSearchApplication.h"
#include "ParamMedicApplication.h"
#include "PSMConvertApplication.h"
#include "tide/mass_constants.h"
#include "TideMatchSet.h"
#include "util/Params.h"
#include "util/FileUtils.h"
#include "util/StringUtils.h"

bool TideSearchApplication::HAS_DECOYS = false;
bool TideSearchApplication::PROTEIN_LEVEL_DECOYS = false;

/* This constant is the product of the original "magic number" (10000,
 * on line 4622 of search28.c) that was used to rescale the XCorr
 * score, and the integerization constant used by Benjamin Diament in
 * Tide.  In the Tide publication, that constant was reported as 10^7.
 * However, here it appears to be only 10^4.
 *
 * --WSN, 10 March 2015 */
const double TideSearchApplication::XCORR_SCALING = 100000000.0;

/* This constant is used to put the refactored XCorr back into the
 * same range as the original XCorr score.  It is the XCorr "magic
 * number" (10000) divided by the EVIDENCE_SCALE_INT (defined in
 * tide/spectrum_preprocess2.cc). */
const double TideSearchApplication::RESCALE_FACTOR = 20.0;

#define SUBCAND 65000
double *nterm_mono_table;
double *cterm_mono_table;
double *mono_table;
double *unique_deltas_;

int **gSpec, **result, **gLen;
char **gChar;
int **gMod, **gModLen;
int **gBin, **gIon;

char **residues;// = (char*) malloc(lMax*nCandPeptide*sizeof(char));
int **mod;// = (int*) malloc(10*nCandPeptide*sizeof(int));
int **leng;// = (int*) malloc(nCandPeptide*sizeof(int));
int **modleng;// = (int*) malloc(nCandPeptide*sizeof(int));

cudaStream_t *streams;

__global__ void CalculateScore(int *gSpec, double *gMass, int *result, int mSize);
__global__ void CalculateScore2(int *gSpec, char *gChar, int *gMod, int *gLen, int *gModLen, int *result,
                                double *nterm_mono_table, double *cterm_mono_table, double *mono_table, double *unique_deltas_,
                                int log_unique_deltas_, int mask_, double max_possible_peak,
                                double bin_width_, double bin_offset_, double B, double Y, double proton);
__global__ void CalculateScore3(int *gSpec, char *gChar, int *gMod, int *gLen, int *gModLen, int *result,
                                double *nterm_mono_table, double *cterm_mono_table, double *mono_table, double *unique_deltas_,
                                int log_unique_deltas_, int mask_, double max_possible_peak,
                                double bin_width_, double bin_offset_, double B, double Y, double proton);
__global__ void ComputeCache1st(int *gBin, int *gIon, int *gSpec, int size, int bSize);
__global__ void ComputeCache2nd(int *gSpec, int aSize, bool FP_, bool NL_, int BIN_NH3, int BIN_H2O);


//float* time_check = new float(0);

TideSearchApplication::TideSearchApplication():
  exact_pval_search_(false), remove_index_(""), spectrum_flag_(NULL) {
}

TideSearchApplication::~TideSearchApplication() {
  if (!remove_index_.empty()) {
    carp(CARP_DEBUG, "Removing temp index '%s'", remove_index_.c_str());
    FileUtils::Remove(remove_index_);
  }
}

int TideSearchApplication::main(int argc, char** argv) {
  return main(Params::GetStrings("tide spectra file"));
}
int TideSearchApplication::main(const vector<string>& input_files) {
  return main(input_files, Params::GetString("tide database"));
}

int TideSearchApplication::main(const vector<string>& input_files, const string input_index) {
  carp(CARP_INFO, "Running tide-search...");

  // prevent different output formats from using threading
  if (Params::GetBool("peptide-centric-search") == true) {
    NUM_THREADS = 1;
    carp(CARP_INFO, "Threading for peptide-centric formats are not supported yet");
  } else {
    NUM_THREADS = Params::GetInt("num-threads");
  }
  if (NUM_THREADS < 1) {
    NUM_THREADS = boost::thread::hardware_concurrency(); // MINIMUM # = 1.
    // (Meaning just main thread) Do not make this value below 1.
  // make sure that number of threads are reasonable, e.g. user did not specify millions of threads...
  } else if (NUM_THREADS > 64) {
    carp(CARP_FATAL, "Requested more than 64 threads.");
  }
  carp(CARP_INFO, "Number of Threads: %d", NUM_THREADS); // prints the number of threads

  const string index = input_index;
  string peptides_file = FileUtils::Join(index, "pepix");
  string proteins_file = FileUtils::Join(index, "protix");
  string auxlocs_file = FileUtils::Join(index, "auxlocs");

  double window = Params::GetDouble("precursor-window");
  WINDOW_TYPE_T window_type = string_to_window_type(Params::GetString("precursor-window-type"));

  // Check spectrum-charge parameter
  string charge_string = Params::GetString("spectrum-charge");
  int charge_to_search;
  if (charge_string == "all") {
    carp(CARP_DEBUG, "Searching all charge states");
    charge_to_search = 0;
  } else {
    charge_to_search = atoi(charge_string.c_str());
    if (charge_to_search < 1 || charge_to_search > 6) {
      carp(CARP_FATAL, "Invalid spectrum-charge value %s", charge_string.c_str());
    }
    carp(CARP_DEBUG, "Searching charge state %d", charge_to_search);
  }

  // Check scan-number parameter
  string scan_range = Params::GetString("scan-number");
  int min_scan, max_scan;
  if (scan_range.empty()) {
    min_scan = 0;
    max_scan = BILLION;
    carp(CARP_DEBUG, "Searching all scans");
  } else if (scan_range.find('-') == string::npos) {
    // Single scan
    min_scan = max_scan = atoi(scan_range.c_str());
    carp(CARP_DEBUG, "Searching single scan %d", min_scan);
  } else {
    if (!get_range_from_string(scan_range.c_str(), min_scan, max_scan)) {
      carp(CARP_FATAL, "The scan number range '%s' is invalid. "
           "Must be of the form <first>-<last>", scan_range.c_str());
    } else {
      if (min_scan > max_scan) {
        int tmp_scan = min_scan;
        min_scan = max_scan;
        max_scan = tmp_scan;
        carp(CARP_DEBUG, "Switched scan range min and max");
      }
      carp(CARP_DEBUG, "Searching scan range %d-%d", min_scan, max_scan);
    }
  }
  //check to compute exact p-value 
  exact_pval_search_ = Params::GetBool("exact-p-value");
  bin_width_  = Params::GetDouble("mz-bin-width");
  bin_offset_ = Params::GetDouble("mz-bin-offset");
  // for now don't allow XCorr p-value searches with variable bin width
  if (exact_pval_search_ && !Params::IsDefault("mz-bin-width")) {
    carp(CARP_FATAL, "Tide-search with XCorr p-values and variable bin width "
                     "is not allowed in this version of Crux.");
  }

  // Check concat parameter
  bool concat = Params::GetBool("concat");

  // Check compute-sp parameter
  bool compute_sp = Params::GetBool("compute-sp");
  if (Params::GetBool("sqt-output") && !compute_sp) {
    compute_sp = true;
    carp(CARP_INFO, "Enabling parameter compute-sp since SQT output is enabled "
                    "(this will increase runtime).");
  }

  // Check isotope-error parameter
  string isotope_errors_string = Params::GetString("isotope-error");
  if (isotope_errors_string[0] == ',') {
    carp(CARP_FATAL, "Error in isotope_error parameter formatting: (%s)", isotope_errors_string.c_str());
  }
  for (int i = 0; isotope_errors_string[i] != '\0'; ++i) {
    if (isotope_errors_string[i] == ',' && (isotope_errors_string[i+1] == ',' || isotope_errors_string[i+1] == '\0')) {
      carp(CARP_FATAL, "Error in isotope_error parameter formatting: (%s) ", isotope_errors_string.c_str());
    }
  }
  
  vector<int>* negative_isotope_errors = new vector<int>();
  negative_isotope_errors->push_back(0);
  
  if (isotope_errors_string != "") {
    vector<int> isotope_errors = StringUtils::Split<int>(Params::GetString("isotope-error"), ',');
    for (vector<int>::iterator it = isotope_errors.begin(); it != isotope_errors.end(); ++it) {
      if (*it < 0) {
        carp(CARP_FATAL, "Found a negative isotope error: %d. There should not be any legitimate reasons to use negative isotope errors. Try modeling with a modification instead.", *it);
      } else if (find(negative_isotope_errors->begin(), negative_isotope_errors->end(), -1 * *it) != negative_isotope_errors->end()) {
        carp(CARP_FATAL, "Found duplicate when parsing isotope_error parameter: %d", *it);
      }
      negative_isotope_errors->push_back(-1 * *it);
    }
  }
  
  sort(negative_isotope_errors->begin(), negative_isotope_errors->end());
  
  carp(CARP_INFO, "Reading index %s", index.c_str());
  // Read proteins index file
  ProteinVec proteins;
  pb::Header protein_header;
  if (!ReadRecordsToVector<pb::Protein, const pb::Protein>(&proteins,
      proteins_file, &protein_header)) {
    carp(CARP_FATAL, "Error reading index (%s)", proteins_file.c_str());
  }
  carp(CARP_DEBUG, "Read %d proteins", proteins.size());

  //open a copy of peptide buffer for Amino Acid Frequency (AAF) calculation.
  double* aaFreqN = NULL;
  double* aaFreqI = NULL;
  double* aaFreqC = NULL;
  int* aaMass = NULL;
  int nAA = 0;
  
  if (exact_pval_search_) {
    pb::Header aaf_peptides_header;
    HeadedRecordReader aaf_peptide_reader(peptides_file, &aaf_peptides_header);

    if ((aaf_peptides_header.file_type() != pb::Header::PEPTIDES) ||
        !aaf_peptides_header.has_peptides_header()) {
      carp(CARP_FATAL, "Error reading index (%s)", peptides_file.c_str());
    }
    MassConstants::Init(&aaf_peptides_header.peptides_header().mods(), 
      &aaf_peptides_header.peptides_header().nterm_mods(), 
      &aaf_peptides_header.peptides_header().cterm_mods(),
                        bin_width_, bin_offset_);
    ActivePeptideQueue* active_peptide_queue =
      new ActivePeptideQueue(aaf_peptide_reader.Reader(), proteins);
    nAA = active_peptide_queue->CountAAFrequency(bin_width_, bin_offset_,
                                                 &aaFreqN, &aaFreqI, &aaFreqC, &aaMass);
    delete active_peptide_queue;
  } // End calculation AA frequencies

  // Read auxlocs index file
  vector<const pb::AuxLocation*> locations;
  if (!ReadRecordsToVector<pb::AuxLocation>(&locations, auxlocs_file)) {
    carp(CARP_FATAL, "Error reading index (%s)", auxlocs_file.c_str());
  }
  carp(CARP_DEBUG, "Read %d auxlocs", locations.size());

  // Read peptides index file
  pb::Header peptides_header;

  vector<HeadedRecordReader*> peptide_reader;
  for (int i = 0; i < NUM_THREADS; i++) {
    peptide_reader.push_back(new HeadedRecordReader(peptides_file, &peptides_header));
  }

  if ((peptides_header.file_type() != pb::Header::PEPTIDES) ||
      !peptides_header.has_peptides_header()) {
    carp(CARP_FATAL, "Error reading index (%s)", peptides_file.c_str());
  }
  
  const pb::Header::PeptidesHeader& pepHeader = peptides_header.peptides_header();
  DECOY_TYPE_T headerDecoyType = (DECOY_TYPE_T)pepHeader.decoys();
  if (headerDecoyType != NO_DECOYS) {
    HAS_DECOYS = true;
    if (headerDecoyType == PROTEIN_REVERSE_DECOYS) {
      PROTEIN_LEVEL_DECOYS = true;
    }
  }

  MassConstants::Init(&pepHeader.mods(), &pepHeader.nterm_mods(), 
    &pepHeader.cterm_mods(), bin_width_, bin_offset_);
  ModificationDefinition::ClearAll();
  TideMatchSet::initModMap(pepHeader.mods(), ANY);
  TideMatchSet::initModMap(pepHeader.nterm_mods(), PEPTIDE_N);
  TideMatchSet::initModMap(pepHeader.cterm_mods(), PEPTIDE_C);

  ofstream* target_file = NULL;
  ofstream* decoy_file = NULL;

  carp(CARP_DEBUG, "Using TideMatchSet to write matches");
  bool overwrite = Params::GetBool("overwrite");
  stringstream ss;
  ss << Params::GetString("enzyme") << '-' << Params::GetString("digestion");
  TideMatchSet::CleavageType = ss.str();
  if (!concat) {
    string target_file_name = make_file_path("tide-search.target.txt");
    target_file = create_stream_in_path(target_file_name.c_str(), NULL, overwrite);
    output_file_name_ = target_file_name;
    if (HAS_DECOYS) {
      string decoy_file_name = make_file_path("tide-search.decoy.txt");
      decoy_file = create_stream_in_path(decoy_file_name.c_str(), NULL, overwrite);
    }
  } else {
    string concat_file_name = make_file_path("tide-search.txt");
    target_file = create_stream_in_path(concat_file_name.c_str(), NULL, overwrite);
    output_file_name_ = concat_file_name;
  }

  if (target_file) {
    TideMatchSet::writeHeaders(target_file, false, compute_sp);
    TideMatchSet::writeHeaders(decoy_file, true, compute_sp);
  }

  // Try to read all spectrum files as spectrumrecords, convert those that fail
  vector<InputFile> input_sr;
  for (vector<string>::const_iterator f = input_files.begin(); f != input_files.end(); f++) {
    SpectrumCollection spectra;
    pb::Header spectrum_header;
    string spectrumrecords = *f;
    bool keepSpectrumrecords = true;
    if (!spectra.ReadSpectrumRecords(spectrumrecords, &spectrum_header)) {
      // Failed, try converting to spectrumrecords file
      carp(CARP_INFO, "Converting %s to spectrumrecords format", f->c_str());
      carp(CARP_INFO, "Elapsed time starting conversion: %.3g s", wall_clock() / 1e6);
      spectrumrecords = Params::GetString("store-spectra");
      keepSpectrumrecords = !spectrumrecords.empty();
      if (!keepSpectrumrecords) {
        spectrumrecords = make_file_path(FileUtils::BaseName(*f) + ".spectrumrecords.tmp");
      } else if (input_files.size() > 1) {
        carp(CARP_FATAL, "Cannot use store-spectra option with multiple input "
                         "spectrum files");
      }
      carp(CARP_DEBUG, "New spectrumrecords filename: %s", spectrumrecords.c_str());
      if (!SpectrumRecordWriter::convert(*f, spectrumrecords)) {
        carp(CARP_FATAL, "Error converting %s to spectrumrecords format", f->c_str());
      }
      carp(CARP_DEBUG, "Reading converted spectra file %s", spectrumrecords.c_str());
      // Re-read converted file as spectrumrecords file
      if (!spectra.ReadSpectrumRecords(spectrumrecords, &spectrum_header)) {
        carp(CARP_DEBUG, "Deleting %s", spectrumrecords.c_str());
        remove(spectrumrecords.c_str());
        carp(CARP_FATAL, "Error reading spectra file %s", spectrumrecords.c_str());
      }
    }
    input_sr.push_back(InputFile(*f, spectrumrecords, keepSpectrumrecords));
  }

  // Loop through spectrum files
  for (vector<InputFile>::const_iterator f = input_sr.begin();
       f != input_sr.end();
       f++) {

    if (!peptide_reader[0]) {
      for (int i = 0; i < NUM_THREADS; i++) {
        peptide_reader[i] = new HeadedRecordReader(peptides_file, &peptides_header);
      }
    }

    vector<ActivePeptideQueue*> active_peptide_queue;
    for (int i = 0; i < NUM_THREADS; i++) {
      active_peptide_queue.push_back(new ActivePeptideQueue(peptide_reader[i]->Reader(), proteins));
      active_peptide_queue[i]->SetBinSize(bin_width_, bin_offset_);
    }

    string spectra_file = f->SpectrumRecords;
    carp(CARP_INFO, "Reading spectra file %s", spectra_file.c_str());
    // Try to read file as spectrumrecords file
    SpectrumCollection spectra;
    pb::Header spectrum_header;
    if (!spectra.ReadSpectrumRecords(spectra_file, &spectrum_header)) {
      // This should never happen since we would have failed earlier
      carp(CARP_FATAL, "Error reading spectra file %s", spectra_file.c_str());
    }

    carp(CARP_INFO, "Sorting spectra");
    if (window_type != WINDOW_MZ) {
      spectra.Sort();
    } else {
      spectra.Sort<ScSortByMz>(ScSortByMz(window));
    }

    double highest_mz = spectra.FindHighestMZ();
    unsigned int spectrum_num = spectra.SpecCharges()->size();
    if (spectrum_num > 0 && exact_pval_search_) {
      highest_mz = spectra.SpecCharges()->at(spectrum_num - 1).neutral_mass;
    }
    carp(CARP_DEBUG, "Max m/z %f", highest_mz);
    MaxBin::SetGlobalMax(highest_mz);
    // Do the search
    carp(CARP_INFO, "Running search");
    if (spectrum_flag_ == NULL) {
      resetMods();
    }
    search(f->OriginalName, spectra.SpecCharges(), active_peptide_queue, proteins,
           locations, window, window_type, Params::GetDouble("spectrum-min-mz"),
           Params::GetDouble("spectrum-max-mz"), min_scan, max_scan,
           Params::GetInt("min-peaks"), charge_to_search,
           Params::GetInt("top-match"), spectra.FindHighestMZ(),
           target_file, decoy_file, compute_sp,
           nAA, aaFreqN, aaFreqI, aaFreqC, aaMass, negative_isotope_errors);

    PSMConvertApplication converter;
    
    // convert tab delimited to other file formats.
    if (!concat) {
      string target_file_name = make_file_path("tide-search.target.txt");
      if (Params::GetBool("pin-output")) {
        converter.convertFile("tsv", "pin", target_file_name, "tide-search.target.", Params::GetString("protein-database"), true);
      }
      if (Params::GetBool("pepxml-output")) {
        converter.convertFile("tsv", "pepxml", target_file_name, "tide-search.target.", Params::GetString("protein-database"), true);
      }
      if (Params::GetBool("mzid-output")) {
        converter.convertFile("tsv", "mzidentml", target_file_name, "tide-search.target.", Params::GetString("protein-database"), true);
      }
      if (Params::GetBool("sqt-output")) {
        converter.convertFile("tsv", "sqt", target_file_name, "tide-search.target.", Params::GetString("protein-database"), true);
      }

      if (HAS_DECOYS) {
        string decoy_file_name = make_file_path("tide-search.decoy.txt");
        if (Params::GetBool("pin-output")) {
          converter.convertFile("tsv", "pin", decoy_file_name, "tide-search.decoy.", Params::GetString("protein-database"), true);
        }
        if (Params::GetBool("pepxml-output")) {
          converter.convertFile("tsv", "pepxml", decoy_file_name, "tide-search.decoy.", Params::GetString("protein-database"), true);
        }
        if (Params::GetBool("mzid-output")) {
          converter.convertFile("tsv", "mzidentml", decoy_file_name, "tide-search.decoy.", Params::GetString("protein-database"), true);
        }
        if (Params::GetBool("sqt-output")) {
          converter.convertFile("tsv", "sqt", decoy_file_name, "tide-search.decoy.", Params::GetString("protein-database"), true);
        }
      }
    } else {
      string concat_file_name = make_file_path("tide-search.txt");
      if (Params::GetBool("pin-output")) {
        converter.convertFile("tsv", "pin", concat_file_name, "tide-search.", Params::GetString("protein-database"), true);
      }
      if (Params::GetBool("pepxml-output")) {
        converter.convertFile("tsv", "pepxml", concat_file_name, "tide-search.", Params::GetString("protein-database"), true);
      }
      if (Params::GetBool("mzid-output")) {
        converter.convertFile("tsv", "mzidentml", concat_file_name, "tide-search.", Params::GetString("protein-database"), true);
      }
      if (Params::GetBool("sqt-output")) {
        converter.convertFile("tsv", "sqt", concat_file_name, "tide-search.", Params::GetString("protein-database"), true);
      }
    }
    
    // Delete temporary spectrumrecords file
    if (!f->Keep) {
      carp(CARP_DEBUG, "Deleting %s", spectra_file.c_str());
      remove(spectra_file.c_str());
    }

    // Clean up
    for (int i = 0; i < NUM_THREADS; i++) {
      delete active_peptide_queue[i];
      delete peptide_reader[i];
      peptide_reader[i] = NULL;
    }

  } // End of spectrum file loop

  delete negative_isotope_errors;
  
  for (ProteinVec::iterator i = proteins.begin(); i != proteins.end(); ++i) {
    delete *i;
  }
  if (target_file) {
    delete target_file;
    if (decoy_file) {
      delete decoy_file;
    }
  }
  delete[] aaFreqN;
  delete[] aaFreqI;
  delete[] aaFreqC;
  delete[] aaMass;

  return 0;
}

void TideSearchApplication::search(void* threadarg) {
  struct thread_data *my_data = (struct thread_data *) threadarg;

  const string& spectrum_filename = my_data->spectrum_filename;
  const vector<SpectrumCollection::SpecCharge>* spec_charges = my_data->spec_charges;
  ActivePeptideQueue* active_peptide_queue = my_data->active_peptide_queue;
  ProteinVec& proteins = my_data->proteins;
  vector<const pb::AuxLocation*>& locations = my_data->locations;
  double precursor_window = my_data->precursor_window;
  WINDOW_TYPE_T window_type = my_data->window_type;
  double spectrum_min_mz = my_data->spectrum_min_mz;
  double spectrum_max_mz = my_data->spectrum_max_mz;
  int min_scan = my_data->min_scan;
  int max_scan = my_data->max_scan;
  int min_peaks = my_data->min_peaks;
  int search_charge = my_data->search_charge;
  int top_matches = my_data->top_matches;
  double highest_mz = my_data->highest_mz;
  ofstream* target_file = my_data -> target_file;
  ofstream* decoy_file = my_data->decoy_file;
  bool compute_sp = my_data->compute_sp;
  int64_t thread_num = my_data->thread_num;
  int64_t num_threads = my_data->num_threads;
  int nAA = my_data->nAA;
  double* aaFreqN = my_data->aaFreqN;
  double* aaFreqI = my_data->aaFreqI;
  double* aaFreqC = my_data->aaFreqC;
  int* aaMass = my_data->aaMass;
  vector<boost::mutex*> locks_array = my_data->locks_array;
  vector<int>* negative_isotope_errors = my_data->negative_isotope_errors;

  double bin_width = my_data->bin_width;
  double bin_offset = my_data->bin_offset;
  bool exact_pval_search = my_data->exact_pval_search;
  map<pair<string, unsigned int>, bool>* spectrum_flag = my_data->spectrum_flag;

  int* sc_index = my_data->sc_index;
  int* total_candidate_peptides = my_data->total_candidate_peptides;

  // params
  bool peptide_centric = Params::GetBool("peptide-centric-search");
  bool use_neutral_loss_peaks = Params::GetBool("use-neutral-loss-peaks");
  bool use_flanking_peaks = Params::GetBool("use-flanking-peaks");
  int max_charge = Params::GetInt("max-precursor-charge");

  // This is the main search loop.
  ObservedPeakSet observed(bin_width, bin_offset,
                           use_neutral_loss_peaks,
                           use_flanking_peaks);    

  // cycle through spectrum-charge pairs, sorted by neutral mass
  FLOAT_T sc_total = (FLOAT_T)spec_charges->size();
  int print_interval = Params::GetInt("print-search-progress");

  for (vector<SpectrumCollection::SpecCharge>::const_iterator sc = spec_charges->begin()+thread_num;
       sc < spec_charges->begin() + (spec_charges->size());
       sc = sc + num_threads) {
    
    locks_array[3]->lock();
    ++(*sc_index);
    if (print_interval > 0 && *sc_index > 0 && *sc_index % print_interval == 0) {
      carp(CARP_INFO, "%d spectrum-charge combinations searched, %.0f%% complete",
           *sc_index, *sc_index / sc_total * 100);
    }
    locks_array[3]->unlock();

    Spectrum* spectrum = sc->spectrum;
    double precursor_mz = spectrum->PrecursorMZ();
    int charge = sc->charge;
    int scan_num = spectrum->SpectrumNumber();
    if (spectrum_flag != NULL) {
      locks_array[1]->lock();
      map<pair<string, unsigned int>, bool>::iterator spectrum_id;
      spectrum_id = spectrum_flag->find(pair<string, unsigned int>(
        spectrum_filename, scan_num * 10 + charge));
      if (spectrum_id != spectrum_flag->end()) {
        locks_array[1]->unlock();
        continue;
      }
      locks_array[1]->unlock();
    }

    if (precursor_mz < spectrum_min_mz || precursor_mz > spectrum_max_mz ||
        scan_num < min_scan || scan_num > max_scan ||
        spectrum->Size() < min_peaks ||
        (search_charge != 0 && charge != search_charge) || charge > max_charge) {
      continue;
    }

    // clock_t thread_time = clock();
    // The active peptide queue holds the candidate peptides for spectrum.
    // Calculate and set the window, depending on the window type.
    vector<double>* min_mass = new vector<double>();
    vector<double>* max_mass = new vector<double>();
    vector<bool>* candidatePeptideStatus = new vector<bool>();
    double min_range, max_range;
    computeWindow(*sc, window_type, precursor_window, max_charge, negative_isotope_errors, min_mass, max_mass, &min_range, &max_range);
    if (!exact_pval_search) {  //execute original tide-search program

      // Normalize the observed spectrum and compute the cache of
      // frequently-needed values for taking dot products with theoretical
      // spectra.
      // observed.PreprocessSpectrum(*spectrum, charge);
      // cudaSetDevice(thread_num%2);
      cudaMemsetAsync(gSpec[thread_num], 0, MaxBin::Global().CacheBinEnd()*NUM_PEAK_TYPES*sizeof(int), streams[thread_num]);
      observed.PreprocessSpectrumHiXCorr(*spectrum, charge);
      int block = observed.max_mz_.CacheBinEnd()/64 + 1;
      cudaMemcpyAsync(gBin[thread_num], observed.bin, observed.size*sizeof(int), cudaMemcpyHostToDevice, streams[thread_num]);
      cudaMemcpyAsync(gIon[thread_num], observed.ion, observed.size*sizeof(int), cudaMemcpyHostToDevice, streams[thread_num]);
      ComputeCache1st<<<block, 64, 0, streams[thread_num]>>>(gBin[thread_num], gIon[thread_num], gSpec[thread_num], observed.size, observed.max_mz_.BackgroundBinEnd());
      ComputeCache2nd<<<block, 64, 0, streams[thread_num]>>>(gSpec[thread_num], observed.max_mz_.CacheBinEnd(), observed.FP_, observed.NL_,
                                   MassConstants::BIN_NH3, MassConstants::BIN_H2O);

      //* ================================================= GPU Algorithm ====================================================
      // const int *cach_ = observed.GetCache();
      // cudaMemcpyAsync(gSpec[thread_num], cach_, MaxBin::Global().CacheBinEnd()*NUM_PEAK_TYPES*sizeof(int), cudaMemcpyHostToDevice);
      int nCandPeptide = active_peptide_queue->SetActiveRangeBYIonsGPU(min_mass, max_mass, min_range, max_range, candidatePeptideStatus);
      if (nCandPeptide == 0) {
        continue;
      }
      locks_array[2]->lock();
      (*total_candidate_peptides) += nCandPeptide;
      locks_array[2]->unlock();

      int candidatePeptideStatusSize = candidatePeptideStatus->size();
      int lMax = active_peptide_queue->lMax;

      int subloop = candidatePeptideStatusSize/SUBCAND + 1;
      int peidx = 0;
      deque<Peptide*>::const_iterator iter_ = active_peptide_queue->iter_;
      deque<Peptide*>::const_iterator iter_1 = active_peptide_queue->iter_;
      TideMatchSet::Arr match_arr(nCandPeptide);
      int *scorelist = new int[candidatePeptideStatusSize];
      int index = 0;

      for(int i=0; i<subloop; i++) {
        int subSize = SUBCAND;
        if(i==subloop-1) subSize = nCandPeptide-(i*SUBCAND);
        if(peidx >= candidatePeptideStatusSize) break;
        index = 0;
        memset(residues[thread_num], '\0', lMax*subSize*sizeof(char));
        memset(mod[thread_num], -1, 10*subSize*sizeof(int));
        cudaMemsetAsync(result[thread_num], 0, subSize*sizeof(int), streams[thread_num]);
        for ( ; peidx < candidatePeptideStatusSize; peidx++) {
          if ((*candidatePeptideStatus)[peidx]) {
            memcpy(residues[thread_num]+(index*lMax), (*iter_)->residues_, (*iter_)->len_*sizeof(char));
            memcpy(mod[thread_num]+(index*10), (*iter_)->mods_, (*iter_)->num_mods_*sizeof(int));
            memcpy(leng[thread_num]+index, &((*iter_)->len_), sizeof(int));
            memcpy(modleng[thread_num]+index, &((*iter_)->num_mods_), sizeof(int));
            index++;
          }
          ++iter_;
          if(index == subSize) {
            peidx++;
            break;
          }
        }
        cudaMemcpyAsync(gChar[thread_num], residues[thread_num], lMax*subSize*sizeof(char), cudaMemcpyHostToDevice, streams[thread_num]);
        cudaMemcpyAsync(gMod[thread_num], mod[thread_num], 10*subSize*sizeof(int), cudaMemcpyHostToDevice, streams[thread_num]);
        cudaMemcpyAsync(gLen[thread_num], leng[thread_num], subSize*sizeof(int), cudaMemcpyHostToDevice, streams[thread_num]);
        cudaMemcpyAsync(gModLen[thread_num], modleng[thread_num], subSize*sizeof(int), cudaMemcpyHostToDevice, streams[thread_num]);
        if(charge > 2) {
          CalculateScore3<<<subSize, lMax, 0, streams[thread_num]>>>(gSpec[thread_num], gChar[thread_num], gMod[thread_num], gLen[thread_num], gModLen[thread_num], result[thread_num],
                                             nterm_mono_table, cterm_mono_table, mono_table, unique_deltas_,
                                             MassConstants::mod_coder_.log_unique_deltas_, MassConstants::mod_coder_.mask_, MaxBin::Global().CacheBinEnd(),
                                             MassConstants::bin_width_, MassConstants::bin_offset_, MassConstants::B, MassConstants::Y, MassConstants::proton);
        }
        else {
          CalculateScore2<<<subSize, lMax, 0, streams[thread_num]>>>(gSpec[thread_num], gChar[thread_num], gMod[thread_num], gLen[thread_num], gModLen[thread_num], result[thread_num],
                                             nterm_mono_table, cterm_mono_table, mono_table, unique_deltas_,
                                             MassConstants::mod_coder_.log_unique_deltas_, MassConstants::mod_coder_.mask_, MaxBin::Global().CacheBinEnd(),
                                             MassConstants::bin_width_, MassConstants::bin_offset_, MassConstants::B, MassConstants::Y, MassConstants::proton);
        }
        cudaMemcpyAsync(scorelist+(i*SUBCAND), result[thread_num], subSize*sizeof(int), cudaMemcpyDeviceToHost, streams[thread_num]);
      }
      index = 0;
      for (peidx = 0; peidx < candidatePeptideStatusSize; peidx++) {
        if ((*candidatePeptideStatus)[peidx]) {
          int score = scorelist[index];
          index++;
          if (peptide_centric) {
              (*iter_1)->AddHit(spectrum, score,0.0,candidatePeptideStatusSize - peidx,charge);
          } else {
            TideMatchSet::Scores curScore;
            curScore.xcorr_score = (double)(score / XCORR_SCALING);
            curScore.rank = candidatePeptideStatusSize - peidx; // TODO ugly hack to conform with the way these indices are generated in standard tide-search
            match_arr.push_back(curScore);
          }
        }
        ++iter_1;
      }

      if (!peptide_centric) {
        TideMatchSet matches(&match_arr, highest_mz);
        matches.exact_pval_search_ = exact_pval_search;
        matches.report(target_file, decoy_file, top_matches, spectrum_filename,
                         spectrum, charge, active_peptide_queue, proteins,
                         locations, compute_sp, true, locks_array[0]);
      }
    } else {  // execute exact-pval-search

      const int minDeltaMass = aaMass[0];
      const int maxDeltaMass = aaMass[nAA - 1];

      int maxPrecurMass = floor(MaxBin::Global().CacheBinEnd() + 50.0); // TODO works, but is this the best way to get?
      int nCandPeptide = active_peptide_queue->SetActiveRangeBIons(min_mass, max_mass, min_range, max_range, candidatePeptideStatus);
      int candidatePeptideStatusSize = candidatePeptideStatus->size();
      locks_array[2]->lock();
      (*total_candidate_peptides) += nCandPeptide;
      locks_array[2]->unlock();

      TideMatchSet::Arr match_arr(nCandPeptide); //scored peptides will go here
  
      // iterators needed at multiple places in following code
      deque<Peptide*>::const_iterator iter_ = active_peptide_queue->iter_;
      deque<TheoreticalPeakSetBIons>::const_iterator iter1_ = active_peptide_queue->iter1_;
      vector<int>::const_iterator iter_int;
      vector<unsigned int>::const_iterator iter_uint;

      //************************************************************************
      /* For one observed spectrum, calculates:
       *  - vector of cleavage evidence
       *  - score count vectors for a range of integer masses
       *  - p-values of XCorr match scores between spectrum and all selected candidate target and decoy peptides
       * Written by Jeff Howbert, October, 2013.
       * Ported to and integrated with Tide by Jeff Howbert, November, 2013.
       */
      int peidx;
      int pe;
      int ma;
      int pepMaInt;
      int* pepMassInt = new int[nCandPeptide];
      vector<int> pepMassIntUnique;
      pepMassIntUnique.reserve(nCandPeptide);
      
      peidx = 0;
      pe = 0;
      for (iter_ = active_peptide_queue->iter_;
           iter_ != active_peptide_queue->end_;
           ++iter_) {
        if ((*candidatePeptideStatus)[peidx]) {
          double pepMass = (*iter_)->Mass();
          pepMaInt = MassConstants::mass2bin(pepMass);
          pepMassInt[pe] = pepMaInt;
          pepMassIntUnique.push_back(pepMaInt);
          pe++;
        }
        peidx++;
      }
      std::sort(pepMassIntUnique.begin(), pepMassIntUnique.end());
      vector<int>::iterator last = std::unique(pepMassIntUnique.begin(),
                                               pepMassIntUnique.end());
      pepMassIntUnique.erase(last, pepMassIntUnique.end());
      int nPepMassIntUniq = (int)pepMassIntUnique.size();

      int** evidenceObs = new int*[nPepMassIntUniq];
      int* scoreOffsetObs = new int[nPepMassIntUniq];
      double** pValueScoreObs = new double*[nPepMassIntUniq];
      int* intensArrayTheor = new int[maxPrecurMass]; // initialized later in loop
      for (pe = 0; pe < nPepMassIntUniq; pe++) { // TODO should probably instead use iterator over pepMassIntUnique
        evidenceObs[pe] = new int[maxPrecurMass];
        for (ma = 0; ma < maxPrecurMass; ma++) {
          evidenceObs[pe][ma] = 0;
        }
        scoreOffsetObs[pe] = 0;
        pepMaInt = pepMassIntUnique[pe]; // TODO should be accessed with an iterator
        // preprocess to create one integerized evidence vector for each cluster of masses among selected peptides
        double pepMassMonoMean = (pepMaInt - 0.5 + bin_offset) * bin_width;
        observed.CreateEvidenceVector(*spectrum, bin_width, bin_offset, charge,
                                      pepMassMonoMean, maxPrecurMass, evidenceObs[pe]);
        // NOTE: will have to go back to separate dynamic programming for
        //       target and decoy if they have different probNI and probC
        int maxEvidence = *std::max_element(evidenceObs[pe], evidenceObs[pe] + maxPrecurMass);
        int minEvidence = *std::min_element(evidenceObs[pe], evidenceObs[pe] + maxPrecurMass);
        // estimate maxScore and minScore
        int maxNResidue = (int)floor((double)pepMaInt / (double)minDeltaMass);
        vector<int> sortEvidenceObs (evidenceObs[pe], evidenceObs[pe] + maxPrecurMass);
        std::sort(sortEvidenceObs.begin(), sortEvidenceObs.end(), greater<int>());
        int maxScore = 0;
        int minScore = 0;
        for (int sc = 0; sc < maxNResidue; sc++) {
          maxScore += sortEvidenceObs[sc];
        }
        for (int sc = maxPrecurMass - maxNResidue; sc < maxPrecurMass; sc++) {
          minScore += sortEvidenceObs[sc];
        }
        int bottomRowBuffer = maxEvidence + 1;
        int topRowBuffer = -minEvidence;
        int nRowDynProg = bottomRowBuffer - minScore + 1 + maxScore + topRowBuffer;
        pValueScoreObs[pe] = new double[nRowDynProg];

        scoreOffsetObs[pe] = calcScoreCount(maxPrecurMass, evidenceObs[pe], pepMaInt,
                                            maxEvidence, minEvidence, maxScore, minScore, 
                                            nAA, aaFreqN, aaFreqI, aaFreqC, aaMass,
                                            pValueScoreObs[pe]);
      }

      // ***** calculate p-values for peptide-spectrum matches ***********************************
      iter_ = active_peptide_queue -> iter_;
      iter1_ = active_peptide_queue -> iter1_;
      pe = 0;
      for (peidx = 0; peidx < candidatePeptideStatusSize; peidx++) { // TODO should probably use iterator instead
        if ((*candidatePeptideStatus)[peidx]) {
          int pepMassIntIdx = 0;
          for (ma = 0; ma < nPepMassIntUniq; ma++) { // TODO should probably use iterator instead
            if (pepMassIntUnique[ma] == pepMassInt[pe]) { // TODO pepMassIntUnique should be accessed with an iterator
              pepMassIntIdx = ma;
              break;
            }
          }
          // score XCorr for target peptide with integerized evidenceObs array
          for (ma = 0; ma < maxPrecurMass; ma++) {
            intensArrayTheor[ma] = 0;
          }
          for (iter_uint = iter1_->unordered_peak_list_.begin();
               iter_uint != iter1_->unordered_peak_list_.end();
               iter_uint++) {
            intensArrayTheor[*iter_uint] = 1;
          }

          int scoreRefactInt = 0;
          for (ma = 0; ma < maxPrecurMass; ma++) {
            scoreRefactInt += evidenceObs[pepMassIntIdx][ma] * intensArrayTheor[ma];
          }
          int scoreCountIdx = scoreRefactInt + scoreOffsetObs[pepMassIntIdx];
          double pValue = pValueScoreObs[pepMassIntIdx][scoreCountIdx];
          if (peptide_centric) {
              (*iter_)->AddHit(spectrum, pValue, (double)scoreRefactInt, candidatePeptideStatusSize - peidx, charge);
          } else {
            TideMatchSet::Scores curScores;
            curScores.xcorr_pval = pValue;
            curScores.xcorr_score = (double)scoreRefactInt / RESCALE_FACTOR;
            curScores.rank = candidatePeptideStatusSize - peidx; // TODO ugly hack to conform with the way these indices are generated in standard tide-search
            match_arr.push_back(curScores);
          }
          ++pe;
        }

        // move to next peptide and b ion queue
        ++iter_; // TODO need to add test to make sure haven't gone past available peptides
        ++iter1_; // TODO need to add test to make sure haven't gone past available b ion queues
      }
      // clean up
      delete [] pepMassInt;
      delete [] scoreOffsetObs;
      for (pe = 0; pe < nPepMassIntUniq; pe++) {
        delete [] evidenceObs[pe];
        delete [] pValueScoreObs[pe];
      }
      delete [] evidenceObs;
      delete [] pValueScoreObs;
      delete [] intensArrayTheor;
      if (!peptide_centric) {
        // matches will arrange the results in a heap by score, return the top
        // few, and recover the association between counter and peptide. We output
        // the top matches.
        TideMatchSet matches(&match_arr, highest_mz);
        matches.exact_pval_search_ = exact_pval_search;

        matches.report(target_file, decoy_file, top_matches, spectrum_filename,
                       spectrum, charge, active_peptide_queue, proteins,
                       locations, compute_sp, false, locks_array[0]);
        
      } // end peptide_centric == true
    } // end exact-pval-search
    delete min_mass;
    delete max_mass;
    delete candidatePeptideStatus;

    // thread_time = clock() - thread_time;

    //locks_array[2]->lock();
    //(*time_check) += (float)thread_time;
    //locks_array[2]->unlock();
  }
}

void TideSearchApplication::search(
  const string& spectrum_filename,
  const vector<SpectrumCollection::SpecCharge>* spec_charges,
  vector<ActivePeptideQueue*> active_peptide_queue,
  ProteinVec& proteins,
  vector<const pb::AuxLocation*>& locations,
  double precursor_window,
  WINDOW_TYPE_T window_type,
  double spectrum_min_mz,
  double spectrum_max_mz,
  int min_scan,
  int max_scan,
  int min_peaks,
  int search_charge,
  int top_matches,
  double highest_mz,
  ofstream* target_file,
  ofstream* decoy_file,
  bool compute_sp,
  int nAA, 
  double* aaFreqN,
  double* aaFreqI,
  double* aaFreqC,
  int* aaMass,
  vector<int>* negative_isotope_errors
) {
  // Create an array of 4 locks.
  // Lock #0: Results file output
  // Lock #1: Only used by cascade-search on spectrum_flag (map)
  // Lock #2: Updating # of candidate peptides
  // Lock #3: Updating sc_index and reporting progress
  int num_locks = 4;
  vector<boost::mutex *> locks_array;

  for (int i = 0; i < num_locks; i++) {
    locks_array.push_back(new boost::mutex());
  }

  int elution_window = Params::GetInt("elution-window-size");
  bool peptide_centric = Params::GetBool("peptide-centric-search");

  // initialize fields required for output
  int* sc_index = new int(-1);
  int* total_candidate_peptides = new int(0);
  FLOAT_T sc_total = (FLOAT_T)spec_charges->size();

  if (peptide_centric == false) {
    elution_window = 0;
  }

  for (int i = 0; i < NUM_THREADS; i++) {
    active_peptide_queue[i]->setElutionWindow(elution_window);
    active_peptide_queue[i]->setPeptideCentric(peptide_centric);
  }

  if (elution_window > 0 && elution_window % 2 == 0) {
    for (int i = 0; i < NUM_THREADS; i++) {
      active_peptide_queue[i]->setElutionWindow(elution_window+1);
    }
  }
  
  if (!peptide_centric || !exact_pval_search_) {
    for (int i = 0; i < NUM_THREADS; i++) {
      active_peptide_queue[i]->setElutionWindow(0);
    }
  }

  for (int i = 0; i < NUM_THREADS; i++) {
    active_peptide_queue[i]->SetOutputs(NULL, &locations, top_matches, compute_sp, target_file, decoy_file, highest_mz);
    active_peptide_queue[i]->lMax = -1;
  }

  cudaMalloc((double **)&nterm_mono_table, 256*sizeof(double));
  cudaMalloc((double **)&cterm_mono_table, 256*sizeof(double));
  cudaMalloc((double **)&mono_table, 256*sizeof(double));
  cudaMemcpy(nterm_mono_table, MassConstants::nterm_mono_table, 256*sizeof(double), cudaMemcpyHostToDevice);
  cudaMemcpy(cterm_mono_table, MassConstants::cterm_mono_table, 256*sizeof(double), cudaMemcpyHostToDevice);
  cudaMemcpy(mono_table, MassConstants::mono_table, 256*sizeof(double), cudaMemcpyHostToDevice);

  cudaMalloc((double **)&unique_deltas_, MassConstants::unique_deltas_.size()*sizeof(double));
  cudaMemcpy(unique_deltas_, &MassConstants::unique_deltas_[0], MassConstants::unique_deltas_.size()*sizeof(double), cudaMemcpyHostToDevice);

  gBin = (int**)malloc(NUM_THREADS*MaxBin::Global().CacheBinEnd()*sizeof(int));
  gIon = (int**)malloc(NUM_THREADS*MaxBin::Global().CacheBinEnd()*sizeof(int));
  gSpec = (int**)malloc(NUM_THREADS*MaxBin::Global().CacheBinEnd()*NUM_PEAK_TYPES*sizeof(int));
  gChar = (char**)malloc(NUM_THREADS*200*SUBCAND*sizeof(char));
  gMod = (int**)malloc(NUM_THREADS*10*SUBCAND*sizeof(int));
  gLen = (int**)malloc(NUM_THREADS*SUBCAND*sizeof(int));
  gModLen= (int**)malloc(NUM_THREADS*SUBCAND*sizeof(int));
  result = (int**)malloc(NUM_THREADS*SUBCAND*sizeof(int));
  
  residues = (char**) malloc(NUM_THREADS*200*SUBCAND*sizeof(char));
  mod = (int**) malloc(NUM_THREADS*10*SUBCAND*sizeof(int));
  leng = (int**) malloc(NUM_THREADS*SUBCAND*sizeof(int));
  modleng = (int**) malloc(NUM_THREADS*SUBCAND*sizeof(int));

  streams = (cudaStream_t *) malloc(NUM_THREADS * sizeof(cudaStream_t));

  for (int i= 0; i < NUM_THREADS; i++) {
    cudaMalloc((int **)&gBin[i], MaxBin::Global().CacheBinEnd()*sizeof(int));
    cudaMalloc((int **)&gIon[i], MaxBin::Global().CacheBinEnd()*sizeof(int));
    cudaMalloc((int **)&gSpec[i], MaxBin::Global().CacheBinEnd()*NUM_PEAK_TYPES*sizeof(int));
    cudaMalloc((char**)&gChar[i], 200*SUBCAND*sizeof(char));
    cudaMalloc((int **)&gMod[i], 10*SUBCAND*sizeof(int));
    cudaMalloc((int **)&gLen[i], SUBCAND*sizeof(int));
    cudaMalloc((int **)&gModLen[i], SUBCAND*sizeof(int));
    cudaMalloc((int **)&result[i], SUBCAND*sizeof(int));

    // residues[i] = (char*) malloc(200*SUBCAND*sizeof(char));
    // mod[i] = (int*) malloc(10*SUBCAND*sizeof(int));
    // leng[i] = (int*) malloc(SUBCAND*sizeof(int));
    // modleng[i] = (int*) malloc(SUBCAND*sizeof(int));
    cudaMallocHost((char**)&residues[i], 200*SUBCAND*sizeof(char));
    cudaMallocHost((int**)&mod[i], 10*SUBCAND*sizeof(int));
    cudaMallocHost((int**)&leng[i], SUBCAND*sizeof(int));
    cudaMallocHost((int**)&modleng[i], SUBCAND*sizeof(int));

    cudaStreamCreate(&(streams[i]));
  }

  // Creating structs to hold information required for each thread to search through
  // a spec charge

  vector<thread_data> thread_data_array;
  for (int i= 0; i < NUM_THREADS; i++) {
      thread_data_array.push_back(thread_data(spectrum_filename, spec_charges, active_peptide_queue[i],
      proteins, locations, precursor_window, window_type, spectrum_min_mz,
      spectrum_max_mz, min_scan, max_scan, min_peaks, search_charge, top_matches,
      highest_mz, target_file, decoy_file, compute_sp,
      i, NUM_THREADS, nAA, aaFreqN, aaFreqI, aaFreqC, aaMass, locks_array, 
      bin_width_, bin_offset_, exact_pval_search_, spectrum_flag_, sc_index, total_candidate_peptides, negative_isotope_errors));
  }

  boost::thread_group threadgroup;

  // Launch threads
  for (int64_t t = 1; t < NUM_THREADS; t++) {
    boost::thread * currthread = new boost::thread(boost::bind(&TideSearchApplication::search, this, (void *) &(thread_data_array[t])));
    threadgroup.add_thread(currthread);
  }

  // Searches through part of the spec charge vector while waiting for threads are busy
  search( (void *) &(thread_data_array[0]) );

  // Join threads
  threadgroup.join_all();

  carp(CARP_INFO, "Time per spectrum-charge combination: %lf s.", wall_clock() / (1e6*sc_total));
  carp(CARP_INFO, "Average number of candidates per spectrum-charge combination: %lf ",
                  (*total_candidate_peptides) / sc_total);
  // carp(CARP_INFO, "Elapesd Time of XCorr: %lf ms",
  //                 (*time_check) / CLOCKS_PER_SEC); 
  for (int i = 0; i < num_locks; i++) {
    delete locks_array[i];
  }
  delete sc_index;
  delete total_candidate_peptides;

  cudaFree(nterm_mono_table);
  cudaFree(cterm_mono_table);
  cudaFree(mono_table);
  cudaFree(unique_deltas_);
  for (int i= 0; i < NUM_THREADS; i++) {
    cudaFree(gSpec[i]);
    cudaFree(gChar[i]);
    cudaFree(gMod[i]);
    cudaFree(result[i]);
    cudaFree(gLen[i]);
    cudaFree(gModLen[i]);
    cudaFree(gBin[i]);
    cudaFree(gIon[i]);

    // delete [] residues[i];
    // delete [] mod[i];
    // delete [] leng[i];
    // delete [] modleng[i];
    cudaFreeHost(residues[i]);
    cudaFreeHost(mod[i]);
    cudaFreeHost(leng[i]);
    cudaFreeHost(modleng[i]);
    cudaStreamDestroy(streams[i]);
  }
  delete [] residues;
  delete [] mod;
  delete [] leng;
  delete [] modleng;

  delete [] gSpec;
  delete [] gChar;
  delete [] gMod;
  delete [] result;
  delete [] gLen;
  delete [] gModLen;
  delete [] gBin;
  delete [] gIon;
  delete [] streams;

}

void TideSearchApplication::collectScoresCompiled(
  ActivePeptideQueue* active_peptide_queue,
  const Spectrum* spectrum,
  const ObservedPeakSet& observed,
  TideMatchSet::Arr2* match_arr,
  int queue_size,
  int charge
) {
  if (!active_peptide_queue->HasNext()) {
    return;
  }
  // prog gets the address of the dot-product program for the first peptide
  // in the active queue.
  const void* prog = active_peptide_queue->NextPeptide()->Prog(charge);
  const int* cache = observed.GetCache();
  // results will get (score, counter) pairs, where score is the dot product
  // of the observed peak set with a candidate peptide. The candidate
  // peptide is given by counter, which refers to the index within the
  // ActivePeptideQueue, counting from the back. This complication
  // simplifies the generated programs, which now simply dump the counter.
  pair<int, int>* results = match_arr->data();

  // See compiler.h for a description of the programs beginning at prog and
  // how they are generated. Here we initialize certain registers to the
  // values expected by the programs and call the first one (*prog).
  //
  // See gnu assembler format for more on this format. We tell the compiler
  // to set these registers:
  // edx/rdx points to the cache.
  // eax/rax points to the first program.
  // ecx/rcx is the counter and gets the size of the active queue.
  // edi/rdi points to the results buffer.
  //
  // The push and pop operations are a workaround for a compiler that
  // doesn't understand that %ecx and %edi (or %rcx and %rdi) get
  // clobbered. Since they're already input registers, they can't be
  // included in the clobber list.

#ifdef _MSC_VER
#ifdef _WIN64
  DWORD64 rcx;
  DWORD64 rdi;

  volatile bool restored = false;
  CONTEXT context;
  RtlCaptureContext(&context);
  if (!restored) {
    rcx = context.Rcx;
    rdi = context.Rdi;

    context.Rdx = (DWORD64)cache;
    context.Rax = (DWORD64)prog;
    context.Rcx = (DWORD64)queue_size;
    context.Rdi = (DWORD64)results;

    restored = true;
    RtlRestoreContext(&context, NULL);
  } else {
    ((void(*)(void))prog)();
  }

  restored = false;
  RtlCaptureContext(&context);
  if (!restored) {
    context.Rcx = rcx;
    context.Rdi = rdi;

    restored = true;
    RtlRestoreContext(&context, NULL);
  }
#else
  __asm {
    cld
    push ecx
    push edi
    mov edx, cache
    mov eax, prog
    mov ecx, queue_size
    mov edi, results
    call eax
    pop edi
    pop ecx
  }
#endif
#else
  __asm__ __volatile__("cld\n" // stos operations increment edi
#ifdef __x86_64__
                       "push %%rcx\n"
                       "push %%rdi\n"
                       "call *%%rax\n"
                       "pop %%rdi\n"
                       "pop %%rcx\n"
#else
                       "push %%ecx\n"
                       "push %%edi\n"
                       "call *%%eax\n"
                       "pop %%edi\n"
                       "pop %%ecx\n"
#endif
                       : // no outputs
                       : "d" (cache),
                         "a" (prog),
                         "c" (queue_size),
                         "D" (results)
  );
#endif

  // match_arr is filled by the compiled programs, not by calls to
  // push_back(). We have to set the final size explicitly.
  match_arr->set_size(queue_size);
}

void TideSearchApplication::computeWindow(
  const SpectrumCollection::SpecCharge& sc,
  WINDOW_TYPE_T window_type,
  double precursor_window,
  int max_charge,
  vector<int>* negative_isotope_errors,
  vector<double>* out_min,
  vector<double>* out_max,
  double* min_range,
  double* max_range
) {
  
  double unit_dalton = BIN_WIDTH;
  
  switch (window_type) {
  case WINDOW_MASS:
    for (vector<int>::const_iterator ie = negative_isotope_errors->begin(); ie != negative_isotope_errors->end(); ++ie) {
      out_min->push_back(sc.neutral_mass + (*ie * unit_dalton) - precursor_window);
      out_max->push_back(sc.neutral_mass + (*ie * unit_dalton) + precursor_window);
    }
    *min_range = (sc.neutral_mass + (negative_isotope_errors->front() * unit_dalton)) - precursor_window;
    *max_range = (sc.neutral_mass + (negative_isotope_errors->back() * unit_dalton)) + precursor_window;
    break;
  case WINDOW_MZ: {
    double mz_minus_proton = sc.spectrum->PrecursorMZ() - MASS_PROTON;
    for (vector<int>::const_iterator ie = negative_isotope_errors->begin(); ie != negative_isotope_errors->end(); ++ie) {
      out_min->push_back((mz_minus_proton - precursor_window) * sc.charge + (*ie * unit_dalton));
      out_max->push_back((mz_minus_proton + precursor_window) * sc.charge + (*ie * unit_dalton));
    }
    *min_range = (mz_minus_proton*sc.charge + (negative_isotope_errors->front() * unit_dalton)) - precursor_window*max_charge;
    *max_range = (mz_minus_proton*sc.charge + (negative_isotope_errors->back() * unit_dalton)) + precursor_window*max_charge;
    break;
  }
  case WINDOW_PPM: {
    double tiny_precursor = precursor_window * 1e-6;
    for (vector<int>::const_iterator ie = negative_isotope_errors->begin(); ie != negative_isotope_errors->end(); ++ie) {
      out_min->push_back((sc.neutral_mass + (*ie * unit_dalton)) * (1.0 - tiny_precursor));
      out_max->push_back((sc.neutral_mass + (*ie * unit_dalton)) * (1.0 + tiny_precursor));
    }
    *min_range = (sc.neutral_mass + (negative_isotope_errors->front() * unit_dalton)) * (1.0 - tiny_precursor);
    *max_range = (sc.neutral_mass + (negative_isotope_errors->back() * unit_dalton)) * (1.0 + tiny_precursor);
    break;
  }
  default:
    carp(CARP_FATAL, "Invalid window type");
  }
  carp(CARP_DETAILED_DEBUG, "Scan %d.%d mass window is [%f, %f]",
       sc.spectrum->SpectrumNumber(), sc.charge, (*out_min)[0], (*out_max)[0]);
}

bool TideSearchApplication::hasDecoys() {
  return HAS_DECOYS;
}

bool TideSearchApplication::proteinLevelDecoys() {
  return PROTEIN_LEVEL_DECOYS;
}

string TideSearchApplication::getName() const {
  return "tide-search";
}

string TideSearchApplication::getDescription() const {
  return
    "[[nohtml:Search a collection of spectra against a sequence database, "
    "returning a collection of peptide-spectrum matches (PSMs). This is a "
    "fast search engine but requires that you first build an index with "
    "tide-index.]]"
    "[[html:<p>Tide is a tool for identifying peptides from tandem mass "
    "spectra. It is an independent reimplementation of the SEQUEST<sup>&reg;"
    "</sup> algorithm, which assigns peptides to spectra by comparing the "
    "observed spectra to a catalog of theoretical spectra derived from a "
    "database of known proteins. Tide's primary advantage is its speed. Our "
    "published paper provides more detail on how Tide works. If you use Tide "
    "in your research, please cite:</p><blockquote>Benjamin J. Diament and "
    "William Stafford Noble. <a href=\"http://dx.doi.org/10.1021/pr101196n\">"
    "&quot;Faster SEQUEST Searching for Peptide Identification from Tandem "
    "Mass Spectra&quot;</a>. <em>Journal of Proteome Research</em>. "
    "10(9):3871-9, 2011.</blockquote> "
    "<p>When <code>tide-search</code> runs, it performs "
    "several intermediate steps, as follows:</p><ol>"
    "<li>If a FASTA file was provided, convert it to an index using "
    "<code>tide-index</code>.</li>"
    "<li>Convert the given "
    "fragmentation spectra to a binary format.</li><li>Search the spectra "
    "against the database and store the results in binary format.</li><li>"
    "Convert the results to one or more requested output formats.</li></ol><p>"
    "By default, the intermediate binary files are stored in the output "
    "directory and deleted when Tide finishes execution. If you plan to search "
    "against given database more than once or search a given set of spectra "
    "more than once, then you can direct Tide to save the binary spectrum "
    "files using the <code>--store-index</code> and "
    "<code>--store-spectra</code> options. "
    "Subsequent runs of the program will go faster "
    "if provided with inputs in binary format.</p>]]";
}

vector<string> TideSearchApplication::getArgs() const {
  string arr[] = {
    "tide spectra file+",
    "tide database"
  };
  return vector<string>(arr, arr + sizeof(arr) / sizeof(string));
}

vector<string> TideSearchApplication::getOptions() const {
  string arr[] = {
    "precursor-window",
    "auto-precursor-window",
    "precursor-window-type",
    "spectrum-min-mz",
    "spectrum-max-mz",
    "min-peaks",
    "spectrum-charge",
    "scan-number",
    "top-match",
    "store-spectra",
    "store-index",
    "concat",
    "compute-sp",
    "remove-precursor-peak",
    "remove-precursor-tolerance",
    "print-search-progress",
    "spectrum-parser",
    "use-z-line",
    "txt-output",
    "sqt-output",
    "pepxml-output",
    "mzid-output",
    "pin-output",
    "fileroot",
    "file-column",
    "output-dir",
    "overwrite",
    "parameter-file",
    "exact-p-value",
    "use-neutral-loss-peaks",
    "use-flanking-peaks",
    "mz-bin-width",
    "auto-mz-bin-width",
    "mz-bin-offset",
    "max-precursor-charge",
    "peptide-centric-search",
    "isotope-error",
    "skip-preprocessing",
    "elution-window-size",
    "num-threads",
    "verbosity",
    "pm-min-precursor-mz",
    "pm-max-precursor-mz",
    "pm-min-frag-mz",
    "pm-max-frag-mz",
    "pm-min-scan-frag-peaks",
    "pm-max-precursor-delta-ppm",
    "pm-charge",
    "pm-top-n-frag-peaks",
    "pm-pair-top-n-frag-peaks",
    "pm-min-common-frag-peaks",
    "pm-max-scan-separation",
    "pm-min-peak-pairs"
  };
  return vector<string>(arr, arr + sizeof(arr) / sizeof(string));
}

vector< pair<string, string> > TideSearchApplication::getOutputs() const {
  vector< pair<string, string> > outputs;
  outputs.push_back(make_pair("tide-search.target.txt",
    "a tab-delimited text file containing the target PSMs. See <a href=\""
    "../file-formats/txt-format.html\">txt file format</a> for a list of the fields."));
  outputs.push_back(make_pair("tide-search.decoy.txt",
    "a tab-delimited text file containing the decoy PSMs. This file will only "
    "be created if the index was created with decoys."));
  outputs.push_back(make_pair("tide-search.params.txt",
    "a file containing the name and value of all parameters/options for the "
    "current operation. Not all parameters in the file may have been used in "
    "the operation. The resulting file can be used with the --parameter-file "
    "option for other Crux programs."));
  outputs.push_back(make_pair("tide-search.log.txt",
    "a log file containing a copy of all messages that were printed to the "
    "screen during execution."));
  return outputs;
}
bool TideSearchApplication::needsOutputDirectory() const {
  return true;
}

COMMAND_T TideSearchApplication::getCommand() const {
  return TIDE_SEARCH_COMMAND;
}

/* Calculates counts of peptides with various XCorr scores, given a preprocessed
 * MS2 spectrum, using dynamic programming.
 * Written by Jeff Howbert, October, 2012 (as function calcScoreCount).
 * Ported to and integrated with Tide by Jeff Howbert, November, 2013.
 */
int TideSearchApplication::calcScoreCount(
  int numelEvidenceObs,
  int* evidenceObs,
  int pepMassInt,
  int maxEvidence,
  int minEvidence,
  int maxScore,
  int minScore,
  int nAA,
  double* aaFreqN,
  double* aaFreqI,
  double* aaFreqC,
  int* aaMass,
  double* pValueScoreObs
) {
  const int nDeltaMass = nAA;
  int minDeltaMass = aaMass[0];
  int maxDeltaMass = aaMass[nDeltaMass - 1];

  // internal variables
  int row;
  int col;
  int ma;
  int evidence;
  int de;
  int evidenceRow;
  double sumScore;

  int bottomRowBuffer = maxEvidence + 1;
  int topRowBuffer = -minEvidence;
  int colBuffer = maxDeltaMass;
  int colStart = MassConstants::mass2bin(MassConstants::mono_h);
  int scoreOffsetObs = bottomRowBuffer - minScore;

  int nRow = bottomRowBuffer - minScore + 1 + maxScore + topRowBuffer;
  int nCol = colBuffer + pepMassInt;
  int rowFirst = bottomRowBuffer;
  int rowLast = rowFirst - minScore + maxScore;
  int colFirst = colStart + MassConstants::mass2bin(MassConstants::mono_h);
  int colLast = MassConstants::mass2bin(MassConstants::bin2mass(pepMassInt)
      - MassConstants::mono_oh 
      );
  int initCountRow = bottomRowBuffer - minScore;
  int initCountCol = maxDeltaMass + colStart;

  double** dynProgArray = new double*[nRow];
  for (row = 0; row < nRow; row++) {
    dynProgArray[row] = new double[nCol];
    for (col = 0; col < nCol; col++) {
      dynProgArray[row][col] = 0.0;
    }
  }
  double* scoreCountBinAdjust = 0;
  scoreCountBinAdjust = new double[nRow];
  for (row = 0; row < nRow; row++) {
    scoreCountBinAdjust[row] = 0.0;
  }

  dynProgArray[initCountRow][initCountCol] = 1.0; // initial count of peptides with mass = 1
  vector<int> deltaMassCol(nDeltaMass);
  // populate matrix with scores for first (i.e. N-terminal) amino acid in sequence
  for (de = 0; de < nDeltaMass; de++) {
    ma = aaMass[de];
    row = initCountRow + evidenceObs[ma + colStart];
    col = initCountCol + ma;
    if (col <= maxDeltaMass + colLast) {
      dynProgArray[row][col] += dynProgArray[initCountRow][initCountCol] * aaFreqN[de];
    }
  }
  // set to zero now that score counts for first amino acid are in matrix
  dynProgArray[initCountRow][initCountCol] = 0.0;
  // populate matrix with score counts for non-terminal amino acids in sequence 
  for (ma = colFirst; ma < colLast; ma++) {
    col = maxDeltaMass + ma;
    evidence = evidenceObs[ma];
    for (de = 0; de < nDeltaMass; de++) {
      deltaMassCol[de] = col - aaMass[de];
    }
    for (row = rowFirst; row <= rowLast; row++) {
      evidenceRow = row - evidence;
      sumScore = dynProgArray[row][col];
      for (de = 0; de < nDeltaMass; de++) {
        sumScore += dynProgArray[evidenceRow][deltaMassCol[de]] * aaFreqI[de];
      }
      dynProgArray[row][col] = sumScore;
    }
  }
  // populate matrix with score counts for last (i.e. C-terminal) amino acid in sequence
  ma = colLast;
  col = maxDeltaMass + ma;
  evidence = 0; // no evidence should be added for last amino acid in sequence
  for (de = 0; de < nDeltaMass; de++) {
    deltaMassCol[de] = col - aaMass[de];
  }
  for (row = rowFirst; row <= rowLast; row++) {
    evidenceRow = row - evidence;
    sumScore = 0.0;
    for (de = 0; de < nDeltaMass; de++) {
      sumScore += dynProgArray[evidenceRow][deltaMassCol[de]] * aaFreqC[de];  // C-terminal residue
    }
    dynProgArray[row][col] = sumScore;
  }

  int colScoreCount = maxDeltaMass + colLast;
  double totalCount = 0.0;
  for (row = 0; row < nRow; row++) {
    // at this point pValueScoreObs just holds counts from last column of dynamic programming array
    pValueScoreObs[row] = dynProgArray[row][colScoreCount];
    totalCount += pValueScoreObs[row];
    scoreCountBinAdjust[row] = pValueScoreObs[row] / 2.0;
  }
  // convert from counts to cumulative sum of counts
  for (row = nRow - 2; row >= 0; row--) {
    pValueScoreObs[row] += pValueScoreObs[row + 1];
  }
  double logTotalCount = log(totalCount);
  for (row = 0; row < nRow; row++) {
    // adjust counts to reflect center of bin, not edge
    pValueScoreObs[row] -= scoreCountBinAdjust[row];
    // normalize distribution; use exp( log ) to avoid potential underflow
    pValueScoreObs[row] = exp(log(pValueScoreObs[row]) - logTotalCount);
  }

  // clean up
  for (row = 0; row < nRow; row++) {
    delete [] dynProgArray[row];
  }
  delete [] dynProgArray;
  delete [] scoreCountBinAdjust;
  
  return scoreOffsetObs;
}

void TideSearchApplication::processParams() {
  const string index = Params::GetString("tide database");
  if (!FileUtils::Exists(index)) {
    carp(CARP_FATAL, "'%s' does not exist", index.c_str());
  } else if (FileUtils::IsRegularFile(index)) {
    // Index is FASTA file
    carp(CARP_INFO, "Creating index from '%s'", index.c_str());
    string targetIndexName = Params::GetString("store-index");
    if (targetIndexName.empty()) {
      targetIndexName = FileUtils::Join(Params::GetString("output-dir"),
                                        "tide-search.tempindex");
      remove_index_ = targetIndexName;
    }
    TideIndexApplication indexApp;
    indexApp.processParams();
    if (indexApp.main(index, targetIndexName) != 0) {
      carp(CARP_FATAL, "tide-index failed.");
    }
    Params::Set("tide database", targetIndexName);
  } else {
    // Index is Tide index directory
    pb::Header peptides_header;
    string peptides_file = FileUtils::Join(index, "pepix");
    HeadedRecordReader peptide_reader(peptides_file, &peptides_header);
    if ((peptides_header.file_type() != pb::Header::PEPTIDES) ||
        !peptides_header.has_peptides_header()) {
      carp(CARP_FATAL, "Error reading index (%s)", peptides_file.c_str());
    }

    const pb::Header::PeptidesHeader& pepHeader = peptides_header.peptides_header();

    Params::Set("enzyme", pepHeader.enzyme());
    const char* digestString =
      digest_type_to_string(pepHeader.full_digestion() ? FULL_DIGEST : PARTIAL_DIGEST);
    Params::Set("digestion", digestString);
    Params::Set("isotopic-mass", pepHeader.monoisotopic_precursor() ? "mono" : "average");
  }
  // run param-medic?
  const string autoPrecursor = Params::GetString("auto-precursor-window");
  const string autoFragment = Params::GetString("auto-mz-bin-width");
  if (autoPrecursor != "false" || autoFragment != "false") {
    if (autoPrecursor != "false" && Params::GetString("precursor-window-type") != "ppm") {
      carp(CARP_FATAL, "Automatic peptide mass tolerance detection is only supported with ppm "
                       "units. Please rerun with either auto-precursor-window set to 'false' or "
                       "precursor-window-type set to 'ppm'.");
    }
    ParamMedicErrorCalculator errCalc;
    errCalc.processFiles(Params::GetStrings("tide spectra file"));
    string precursorFailure, fragmentFailure;
    double precursorSigmaPpm = 0;
    double fragmentSigmaPpm = 0;
    double fragmentSigmaTh = 0;
    double precursorPredictionPpm = 0;
    double fragmentPredictionPpm = 0;
    double fragmentPredictionTh = 0;
    errCalc.calcMassErrorDist(&precursorFailure, &fragmentFailure,
                              &precursorSigmaPpm, &fragmentSigmaPpm,
                              &precursorPredictionPpm, &fragmentPredictionTh);

    if (autoPrecursor != "false") {
      if (precursorFailure.empty()) {
        carp(CARP_INFO, "precursor ppm standard deviation: %f", precursorSigmaPpm);
        carp(CARP_INFO, "Precursor error estimate (ppm): %.2f", precursorPredictionPpm);
        Params::Set("precursor-window", precursorPredictionPpm);
      } else {
        carp(autoPrecursor == "fail" ? CARP_FATAL : CARP_ERROR,
             "failed to calculate precursor error: %s", precursorFailure.c_str());
      }
    }
    if (autoFragment != "false") {
      if (fragmentFailure.empty()) {
        carp(CARP_INFO, "fragment standard deviation (ppm): %f", fragmentSigmaPpm);
        carp(CARP_INFO, "Fragment bin size estimate (Th): %.4f", fragmentPredictionTh);
        Params::Set("mz-bin-width", fragmentPredictionTh);
      } else {
        carp(autoFragment == "fail" ? CARP_FATAL : CARP_ERROR,
             "failed to calculate fragment error: %s", fragmentFailure.c_str());
      }
    }
  }
}

void TideSearchApplication::setSpectrumFlag(map<pair<string, unsigned int>, bool>* spectrum_flag) {
  spectrum_flag_ = spectrum_flag;
}

string TideSearchApplication::getOutputFileName() {
  return output_file_name_;
}

__global__ void CalculateScore(int *gSpec, double *gMass, int *result, int mSize) {
  int charge = threadIdx.x;
  int peak = blockIdx.x*blockDim.x + threadIdx.y;
  if(gMass[peak] != 0) {

  }
}

__global__ void CalculateScore2(int *gSpec, char *gChar, int *gMod, int *gLen, int *gModLen, int *result,
                                double *nterm_mono_table, double *cterm_mono_table, double *mono_table, double *unique_deltas_,
                                int log_unique_deltas_, int mask_, double max_possible_peak,
                                double bin_width_, double bin_offset_, double B, double Y, double proton) {
  __shared__ double aaMass[200];
  __shared__ int bion[200];
  __shared__ int yion[200];
  int nChar = threadIdx.x;
  int nCand = blockIdx.x;
  int pos = blockIdx.x*blockDim.x + threadIdx.x;
  int length = gLen[nCand];
  if(nChar == 0) aaMass[nChar] = nterm_mono_table[gChar[pos]];
  else if(nChar == length-1) aaMass[nChar] = cterm_mono_table[gChar[pos]];
  else aaMass[nChar] = mono_table[gChar[pos]];
  __syncthreads();

  if(nChar == 0) {
    for (int i = 0; i < gModLen[nCand]; ++i) {
      int mPos = blockIdx.x*10+i;
      int aa_index = gMod[mPos] >> log_unique_deltas_;
      int unique_delta_index = gMod[mPos] & mask_;
      aaMass[aa_index] += unique_deltas_[unique_delta_index];
    }

    for(int i=1;i<length;i++) {
      aaMass[i] += aaMass[i-1];
    }
  }
  __syncthreads();

  double ion = aaMass[nChar];
  bion[nChar] = -1;
  if(ion <= max_possible_peak && nChar != length-1)
    bion[nChar] = (unsigned int)((ion+B+proton)/bin_width_ + 1.0 - bin_offset_);

  ion = aaMass[length-1];
  if(nChar != 0) ion -= aaMass[nChar-1];
  yion[nChar] = -1;
  if(ion <= max_possible_peak && nChar != 0)
    yion[nChar] = (unsigned int)((ion+Y+proton)/bin_width_ + 1.0 - bin_offset_);
  __syncthreads();

  int cIon = yion[nChar];
  for(int i=0;i<length;i++) {
    if(bion[i] == cIon) yion[nChar] = -1;
  }

  if(nChar < length) {
    int bin = 0;
    int sum = 0;
    if(bion[nChar] != -1) {
      bin = bion[nChar] * NUM_PEAK_TYPES + PeakCombinedB1;
      sum += gSpec[bin];
      // atomicAdd(&result[nCand], gSpec[bin]);
    }
    if(yion[nChar] != -1) {
      bin = yion[nChar] * NUM_PEAK_TYPES + PeakCombinedY1;
      sum += gSpec[bin];
      // atomicAdd(&result[nCand], gSpec[bin]);
    }
    atomicAdd(&result[nCand], sum);
  }
}

__global__ void CalculateScore3(int *gSpec, char *gChar, int *gMod, int *gLen, int *gModLen, int *result,
                                double *nterm_mono_table, double *cterm_mono_table, double *mono_table, double *unique_deltas_,
                                int log_unique_deltas_, int mask_, double max_possible_peak,
                                double bin_width_, double bin_offset_, double B, double Y, double proton) {
  __shared__ double aaMass[200];
  __shared__ int bion[200];
  __shared__ int yion[200];
  __shared__ int b2ion[200];
  __shared__ int y2ion[200];
  int nChar = threadIdx.x;
  int nCand = blockIdx.x;
  int pos = blockIdx.x*blockDim.x + threadIdx.x;
  int length = gLen[nCand];
  if(nChar == 0) aaMass[nChar] = nterm_mono_table[gChar[pos]];
  else if(nChar == length-1) aaMass[nChar] = cterm_mono_table[gChar[pos]];
  else aaMass[nChar] = mono_table[gChar[pos]];
  __syncthreads();

  if(nChar == 0) {
    for (int i = 0; i < gModLen[nCand]; ++i) {
      int mPos = blockIdx.x*10+i;
      int aa_index = gMod[mPos] >> log_unique_deltas_;
      int unique_delta_index = gMod[mPos] & mask_;
      aaMass[aa_index] += unique_deltas_[unique_delta_index];
    }

    for(int i=1;i<length;i++) {
      aaMass[i] += aaMass[i-1];
    }
  }
  __syncthreads();

  double ion = aaMass[nChar];
  double max_possible_peak2 = max_possible_peak*2 + 2;
  bion[nChar] = -1;
  b2ion[nChar] = -1;
  if(nChar != length-1) {
    ion += B;
    ion += proton;
    if(ion <= max_possible_peak) bion[nChar] = (unsigned int)(ion/bin_width_ + 1.0 - bin_offset_);
    if(ion <= max_possible_peak2) b2ion[nChar] = (unsigned int)((ion+proton)/(2*bin_width_) + 1.0 - bin_offset_);
  }

  ion = aaMass[length-1];
  yion[nChar] = -1;
  y2ion[nChar] = -1;
  if(nChar != 0) {
    ion -= aaMass[nChar-1];
    ion += Y;
    ion += proton;
    if(ion <= max_possible_peak) yion[nChar] = (unsigned int)(ion/bin_width_ + 1.0 - bin_offset_);
    if(ion <= max_possible_peak2) y2ion[nChar] = (unsigned int)((ion+proton)/(2*bin_width_) + 1.0 - bin_offset_);
  }
  __syncthreads();

  int cIon = yion[nChar];
  for(int i=0;i<length;i++) {
    if(bion[i] == cIon) yion[nChar] = -1;
  }
  cIon = b2ion[nChar];
  for(int i=0;i<length;i++) {
    if(bion[i] == cIon) b2ion[nChar] = -1;
    if(yion[i] == cIon) b2ion[nChar] = -1;
  }
  cIon = y2ion[nChar];
  for(int i=0;i<length;i++) {
    if(bion[i] == cIon) y2ion[nChar] = -1;
    if(yion[i] == cIon) y2ion[nChar] = -1;
    if(b2ion[i] == cIon) y2ion[nChar] = -1;
  }


  if(nChar < length) {
    int bin = 0;
    int sum = 0;
    if(bion[nChar] != -1) {
      bin = bion[nChar] * NUM_PEAK_TYPES + PeakCombinedB1;
      sum += gSpec[bin];
    }
    if(yion[nChar] != -1) {
      bin = yion[nChar] * NUM_PEAK_TYPES + PeakCombinedY1;
      sum += gSpec[bin];
    }
    if(b2ion[nChar] != -1) {
      bin = b2ion[nChar] * NUM_PEAK_TYPES + PeakCombinedB2;
      sum += gSpec[bin];
    }
    if(y2ion[nChar] != -1) {
      bin = y2ion[nChar] * NUM_PEAK_TYPES + PeakCombinedY2;
      sum += gSpec[bin];
    }
    atomicAdd(&result[nCand], sum);
  }
}

__global__ void ComputeCache1st(int *gBin, int *gIon, int *gSpec, int size, int bSize)
{
  int bin = blockIdx.x*blockDim.x + threadIdx.x;
  int globalBin = bin*NUM_PEAK_TYPES;

  if(bin < bSize) {
    int pos = 0;  
    while(bin >= gBin[pos] && pos < size) pos++;
    int x = gIon[pos-1];
    gSpec[globalBin+LossPeak] = x+x;
    gSpec[globalBin+FlankingPeak] = 5*x;
    gSpec[globalBin+PrimaryPeak] = 10*x;
  }
}
__global__ void ComputeCache2nd(int *gSpec, int aSize, bool FP_, bool NL_, int BIN_NH3, int BIN_H2O)
{
  int bin = blockIdx.x*blockDim.x + threadIdx.x;
  int globalBin = bin*NUM_PEAK_TYPES;
  if(bin < aSize) {
    int flanks = gSpec[globalBin+PrimaryPeak];
    if ( FP_ == true) {
        if (bin > 0) {
          flanks += gSpec[(bin-1)*NUM_PEAK_TYPES+FlankingPeak];
        }
        if (bin < (aSize - 1)) {
          flanks += gSpec[(bin+1)*NUM_PEAK_TYPES+FlankingPeak];
        }
    }
    int Y1 = flanks;
    if ( NL_ == true) {
        if (bin > BIN_NH3) {
          Y1 += gSpec[(bin-BIN_NH3)*NUM_PEAK_TYPES+LossPeak];
        }
        if (bin > BIN_H2O) {
          Y1 += gSpec[(bin-BIN_H2O)*NUM_PEAK_TYPES+LossPeak];
        }
    }
    gSpec[globalBin+PeakCombinedY1] = Y1;
    gSpec[globalBin+PeakCombinedB1] = Y1;
    gSpec[globalBin+PeakCombinedY2] = flanks;
    gSpec[globalBin+PeakCombinedB2] = flanks;
  }
}

/*
 * Local Variables:
 * mode: c
 * c-basic-offset: 2
 * End:
 */
