// Persistent worker pool with a chunked parallel_for (the calling thread participates).
#pragma once
#include <atomic>
#include <cstdint>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>
#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
#include <xmmintrin.h>
#endif

namespace scl {

/// Flush denormals to zero on this thread. Detonation spreads tiny values (< 1e-38) ahead of the front;
/// x86 CPUs handle those through a ~100× slower microcode path. They have no physical effect here.
inline void enableFlushToZero() {
#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
    _mm_setcsr(_mm_getcsr() | 0x8040);   // FTZ | DAZ
#elif defined(__aarch64__) && !defined(__APPLE__) && !defined(_MSC_VER)
    uint64_t fpcr;
    __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
    __asm__ volatile("msr fpcr, %0" : : "r"(fpcr | (1ull << 24)));
#endif
}

class ThreadPool {
public:
    explicit ThreadPool(int threads) { resize(threads); }
    ~ThreadPool() { stopAll(); }

    void resize(int threads) {
        threads = std::max(1, threads);
        if (threads == int(workers_.size()) + 1) return;
        stopAll();
        stop_ = false;
        for (int k = 0; k < threads - 1; k++) workers_.emplace_back([this] { enableFlushToZero(); workerLoop(); });
    }
    int size() const { return int(workers_.size()) + 1; }

    /// Runs fn(begin, end) over [0, count) in chunks.
    void parallelFor(size_t count, const std::function<void(size_t, size_t)>& fn, size_t chunk = 1024) {
        if (count == 0) return;
        if (workers_.empty() || count <= chunk) { fn(0, count); return; }
        {
            std::lock_guard<std::mutex> l(m_);
            job_ = &fn; count_ = count; chunk_ = chunk; next_ = 0;
            pending_ = int(workers_.size());
            generation_++;
        }
        cv_.notify_all();
        work();
        std::unique_lock<std::mutex> l(m_);
        done_.wait(l, [this] { return pending_ == 0; });
        job_ = nullptr;
    }

private:
    void work() {
        for (;;) {
            size_t b = next_.fetch_add(chunk_);
            if (b >= count_) break;
            (*job_)(b, std::min(count_, b + chunk_));
        }
    }
    void workerLoop() {
        uint64_t seen = 0;
        for (;;) {
            {
                std::unique_lock<std::mutex> l(m_);
                cv_.wait(l, [&] { return stop_ || generation_ != seen; });
                if (stop_) return;
                seen = generation_;
            }
            work();
            std::lock_guard<std::mutex> l(m_);
            if (--pending_ == 0) done_.notify_one();
        }
    }
    void stopAll() {
        { std::lock_guard<std::mutex> l(m_); stop_ = true; }
        cv_.notify_all();
        for (auto& t : workers_) t.join();
        workers_.clear();
    }

    std::vector<std::thread> workers_;
    std::mutex m_;
    std::condition_variable cv_, done_;
    const std::function<void(size_t, size_t)>* job_ = nullptr;
    size_t count_ = 0, chunk_ = 1024;
    std::atomic<size_t> next_{0};
    int pending_ = 0;
    uint64_t generation_ = 0;
    bool stop_ = false;
};

}  // namespace scl
