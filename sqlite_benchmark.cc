#include <iostream>
#include <vector>
#include <string>
#include <chrono>
#include <random>
#include <sstream>
#include <iomanip>
#include <sys/stat.h>
#include <unistd.h>

// You will need to download cxxopts.hpp from https://github.com/jarro2783/cxxopts
// It's a header-only library, so just place it in your project directory.
#include "cxxopts.hpp"
#include "sqlite3.h"

// --- Utility Functions ---

void CheckSqliteError(int rc, const std::string& message, sqlite3* db = nullptr) {
    if (rc != SQLITE_OK) {
        std::cerr << "SQLite Error: " << message << std::endl;
        if (db) {
            std::cerr << "  Details: " << sqlite3_errmsg(db) << std::endl;
            sqlite3_close(db);
        }
        exit(EXIT_FAILURE);
    }
}

std::vector<std::string> split(const std::string& s, char delimiter) {
    std::vector<std::string> tokens;
    std::string token;
    std::istringstream tokenStream(s);
    while (std::getline(tokenStream, token, delimiter)) {
        tokens.push_back(token);
    }
    return tokens;
}

// --- Benchmark Class ---

class Benchmark {
private:
    sqlite3* db_ = nullptr;
    std::string db_path_;
    int num_entries_;
    int value_size_;
    std::vector<std::string> pragmas_;
    std::mt19937_64 rng_;

    void openDatabase() {
        if (db_path_ != ":memory:") {
            unlink(db_path_.c_str());
        }

        int rc = sqlite3_open(db_path_.c_str(), &db_);
        CheckSqliteError(rc, "Cannot open database: " + db_path_, db_);

        for (const auto& pragma_str : pragmas_) {
            char* err_msg = nullptr;
            std::string full_pragma = "PRAGMA " + pragma_str + ";";
            rc = sqlite3_exec(db_, full_pragma.c_str(), 0, 0, &err_msg);
            if (rc != SQLITE_OK) {
                std::cerr << "Failed to execute PRAGMA: " << full_pragma << std::endl;
                std::cerr << "  Error: " << err_msg << std::endl;
                sqlite3_free(err_msg);
                sqlite3_close(db_);
                exit(EXIT_FAILURE);
            }
        }

        const char* create_sql = "CREATE TABLE IF NOT EXISTS test (key INTEGER PRIMARY KEY, value BLOB);";
        char* err_msg = nullptr;
        rc = sqlite3_exec(db_, create_sql, 0, 0, &err_msg);
        if (rc != SQLITE_OK) {
            std::cerr << "Failed to create table." << std::endl;
            std::cerr << "  Error: " << err_msg << std::endl;
            sqlite3_free(err_msg);
            sqlite3_close(db_);
            exit(EXIT_FAILURE);
        }
    }

    void closeDatabase() {
        if (db_) {
            sqlite3_close(db_);
            db_ = nullptr;
        }
    }

    void report(const std::string& name, int num_ops, double duration_sec) {
        double ops_per_sec = num_ops / duration_sec;
        std::cout << std::left << std::setw(20) << name << ": "
                  << std::fixed << std::setprecision(2) << ops_per_sec
                  << " ops/sec (" << num_ops << " ops in " << duration_sec << "s)" << std::endl;
    }

public:
    Benchmark(std::string path, int num, int val_size, std::string pragma_str)
        : db_path_(std::move(path)),
          num_entries_(num),
          value_size_(val_size) {
        
        if (!pragma_str.empty()) {
            pragmas_ = split(pragma_str, ',');
        }
        std::random_device rd;
        rng_.seed(rd());
    }

    ~Benchmark() {
        closeDatabase();
    }

    void run(const std::vector<std::string>& benchmarks_to_run) {
        std::cout << "--- Benchmark Configuration ---" << std::endl;
        std::cout << "Database path: " << db_path_ << std::endl;
        std::cout << "Entries:       " << num_entries_ << std::endl;
        std::cout << "Value Size:    " << value_size_ << " bytes" << std::endl;
        std::cout << "PRAGMAs:       ";
        if (pragmas_.empty()) {
            std::cout << "[defaults]";
        } else {
            for(size_t i = 0; i < pragmas_.size(); ++i) {
                std::cout << pragmas_[i] << (i == pragmas_.size() - 1 ? "" : ", ");
            }
        }
        std::cout << "\n-----------------------------" << std::endl;

        for (const auto& bench_name : benchmarks_to_run) {
            openDatabase();
            // --- MODIFIED: Added call to readseq benchmark ---
            if (bench_name == "fillseq") fillSequential();
            else if (bench_name == "fillrandom") fillRandom();
            else if (bench_name == "readrandom") {
                fillRandom(true);
                readRandom();
            } else if (bench_name == "readseq") {
                fillRandom(true);
                readSequential();
            } else if (bench_name == "readwrite") {
                fillRandom(true);
                readWrite();
            } else {
                std::cerr << "Unknown benchmark: " << bench_name << std::endl;
            }
            closeDatabase();
        }
    }

    void fillSequential(bool silent = false) {
        sqlite3_stmt* stmt;
        const char* sql = "INSERT INTO test (key, value) VALUES (?, ?)";
        CheckSqliteError(sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr), "prepare insert", db_);

        std::vector<char> value_buffer(value_size_, 'x');
        auto start = std::chrono::high_resolution_clock::now();

        CheckSqliteError(sqlite3_exec(db_, "BEGIN TRANSACTION", 0, 0, 0), "begin transaction", db_);
        for (int i = 0; i < num_entries_; ++i) {
            sqlite3_bind_int(stmt, 1, i);
            sqlite3_bind_blob(stmt, 2, value_buffer.data(), value_size_, SQLITE_STATIC);
            if (sqlite3_step(stmt) != SQLITE_DONE) {
                CheckSqliteError(SQLITE_ERROR, "step insert", db_);
            }
            sqlite3_reset(stmt);
        }
        CheckSqliteError(sqlite3_exec(db_, "COMMIT", 0, 0, 0), "commit transaction", db_);

        auto end = std::chrono::high_resolution_clock::now();
        std::chrono::duration<double> elapsed = end - start;

        sqlite3_finalize(stmt);
        
        if (!silent) {
            report("fillseq", num_entries_, elapsed.count());
        }
    }

    void fillRandom(bool silent = false) {
        sqlite3_stmt* stmt;
        const char* sql = "INSERT INTO test (key, value) VALUES (?, ?)";
        CheckSqliteError(sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr), "prepare insert", db_);

        std::vector<char> value_buffer(value_size_, 'x');
        std::uniform_int_distribution<int64_t> dist(0, num_entries_ * 10);
        auto start = std::chrono::high_resolution_clock::now();

        CheckSqliteError(sqlite3_exec(db_, "BEGIN TRANSACTION", 0, 0, 0), "begin transaction", db_);
        for (int i = 0; i < num_entries_; ++i) {
            sqlite3_bind_int64(stmt, 1, dist(rng_));
            sqlite3_bind_blob(stmt, 2, value_buffer.data(), value_size_, SQLITE_STATIC);
            sqlite3_step(stmt);
            sqlite3_reset(stmt);
        }
        CheckSqliteError(sqlite3_exec(db_, "COMMIT", 0, 0, 0), "commit transaction", db_);

        auto end = std::chrono::high_resolution_clock::now();
        std::chrono::duration<double> elapsed = end - start;
        
        sqlite3_finalize(stmt);
        
        if (!silent) {
            report("fillrandom", num_entries_, elapsed.count());
        }
    }

    void readRandom() {
        sqlite3_stmt* stmt;
        const char* sql = "SELECT value FROM test WHERE key = ?";
        CheckSqliteError(sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr), "prepare select", db_);
        
        std::uniform_int_distribution<int64_t> dist(0, num_entries_ - 1);
        int found_count = 0;
        auto start = std::chrono::high_resolution_clock::now();

        for (int i = 0; i < num_entries_; ++i) {
            sqlite3_bind_int64(stmt, 1, dist(rng_));
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                found_count++;
            }
            sqlite3_reset(stmt);
        }

        auto end = std::chrono::high_resolution_clock::now();
        std::chrono::duration<double> elapsed = end - start;

        sqlite3_finalize(stmt);
        report("readrandom", num_entries_, elapsed.count());
    }

    // --- MODIFIED: Added new readSequential benchmark function ---
    void readSequential() {
        sqlite3_stmt* stmt;
        const char* sql = "SELECT key, value FROM test ORDER BY key";
        CheckSqliteError(sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr), "prepare select", db_);
        
        int found_count = 0;
        auto start = std::chrono::high_resolution_clock::now();

        while (sqlite3_step(stmt) == SQLITE_ROW) {
            found_count++;
        }

        auto end = std::chrono::high_resolution_clock::now();
        std::chrono::duration<double> elapsed = end - start;

        sqlite3_finalize(stmt);
        report("readseq", found_count, elapsed.count());
    }

    void readWrite() {
        sqlite3_stmt* read_stmt;
        const char* read_sql = "SELECT value FROM test WHERE key = ?";
        CheckSqliteError(sqlite3_prepare_v2(db_, read_sql, -1, &read_stmt, nullptr), "prepare read", db_);
        
        sqlite3_stmt* write_stmt;
        const char* write_sql = "INSERT OR REPLACE INTO test (key, value) VALUES (?, ?)";
        CheckSqliteError(sqlite3_prepare_v2(db_, write_sql, -1, &write_stmt, nullptr), "prepare write", db_);

        std::uniform_int_distribution<int64_t> key_dist(0, num_entries_ - 1);
        std::uniform_int_distribution<int> op_dist(0, 1);
        std::vector<char> value_buffer(value_size_, 'y');
        auto start = std::chrono::high_resolution_clock::now();

        CheckSqliteError(sqlite3_exec(db_, "BEGIN TRANSACTION", 0, 0, 0), "begin transaction", db_);
        for (int i = 0; i < num_entries_; ++i) {
            int64_t key = key_dist(rng_);
            if (op_dist(rng_) == 0) {
                sqlite3_bind_int64(read_stmt, 1, key);
                sqlite3_step(read_stmt);
                sqlite3_reset(read_stmt);
            } else {
                sqlite3_bind_int64(write_stmt, 1, key);
                sqlite3_bind_blob(write_stmt, 2, value_buffer.data(), value_size_, SQLITE_STATIC);
                sqlite3_step(write_stmt);
                sqlite3_reset(write_stmt);
            }
        }
        CheckSqliteError(sqlite3_exec(db_, "COMMIT", 0, 0, 0), "commit transaction", db_);

        auto end = std::chrono::high_resolution_clock::now();
        std::chrono::duration<double> elapsed = end - start;

        sqlite3_finalize(read_stmt);
        sqlite3_finalize(write_stmt);
        report("readwrite", num_entries_, elapsed.count());
    }
};

// --- Main Function ---

int main(int argc, char** argv) {
    cxxopts::Options options("sqlite_benchmark", "A flexible C++ benchmark for SQLite3");

    options.add_options()
        ("b,benchmarks", "Comma-separated list of benchmarks to run (e.g., fillseq,readrandom)", cxxopts::value<std::string>()->default_value("fillrandom,readrandom"))
        ("d,db_path", "Path to the database file or :memory:", cxxopts::value<std::string>()->default_value("/tmp/test.db"))
        ("n,num", "Number of entries for the benchmark", cxxopts::value<int>()->default_value("100000"))
        ("v,value_size", "Size of each value in bytes", cxxopts::value<int>()->default_value("100"))
        ("p,pragmas", "Comma-separated list of PRAGMA commands (e.g., 'journal_mode=WAL,synchronous=NORMAL')", cxxopts::value<std::string>()->default_value(""))
        ("h,help", "Print usage");

    auto result = options.parse(argc, argv);

    if (result.count("help")) {
        std::cout << options.help() << std::endl;
        return 0;
    }

    std::string benchmarks_str = result["benchmarks"].as<std::string>();
    std::string db_path = result["db_path"].as<std::string>();
    int num_entries = result["num"].as<int>();
    int value_size = result["value_size"].as<int>();
    std::string pragmas = result["pragmas"].as<std::string>();

    std::vector<std::string> benchmarks_to_run = split(benchmarks_str, ',');

    Benchmark bench(db_path, num_entries, value_size, pragmas);
    bench.run(benchmarks_to_run);

    return 0;
}
