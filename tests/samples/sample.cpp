#include <vector>

namespace demo {
template <typename T>
class Box {
public:
    explicit Box(T value) : value_(value) {}
    T get() const noexcept { return value_; } // read
private:
    T value_;
};
}  // namespace demo

auto raw = R"(no \escapes)";
int main() { std::vector<int> v{1, 2}; return v.empty() ? 1 : 0; }
