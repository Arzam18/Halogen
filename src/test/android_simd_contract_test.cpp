// Host-side arithmetic contract checks for Halogen's ARM NEON and Dotprod NNUE paths.
// These checks validate the integer identities used by the target intrinsics without
// requiring an ARM device. The Android workflow separately verifies emitted instructions.
#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include <random>

namespace
{

int32_t x86_mulhi_scaled(int a, int b)
{
    // Halogen's x86 FT activation: clamp, shift left by 7, then signed PMULHW.
    const int32_t lhs = a << 7;
    return (lhs * b) >> 16;
}

int32_t neon_sqdmulh_scaled(int a, int b)
{
    // Halogen's NEON FT activation: clamp, shift left by 6, then SQDMULH.
    // SQDMULH computes the high half of the doubled signed product.
    const int32_t lhs = a << 6;
    return (lhs * b * 2) >> 16;
}

int32_t scalar_dot4(const uint8_t* activations, const int8_t* weights, int32_t source)
{
    int32_t result = source;
    for (int i = 0; i < 4; ++i)
    {
        result += static_cast<int32_t>(activations[i]) * static_cast<int32_t>(weights[i]);
    }
    return result;
}

int32_t neon_pairwise_dot4(const uint8_t* activations, const int8_t* weights, int32_t source)
{
    // Mirrors vmull_s8 + vpaddq_s16 + vpadalq_s16 for one four-byte output group.
    const int16_t p0 = static_cast<int16_t>(activations[0]) * weights[0];
    const int16_t p1 = static_cast<int16_t>(activations[1]) * weights[1];
    const int16_t p2 = static_cast<int16_t>(activations[2]) * weights[2];
    const int16_t p3 = static_cast<int16_t>(activations[3]) * weights[3];
    const int16_t pair0 = static_cast<int16_t>(p0 + p1);
    const int16_t pair1 = static_cast<int16_t>(p2 + p3);
    return source + static_cast<int32_t>(pair0) + static_cast<int32_t>(pair1);
}

bool check_activation_scaling()
{
    for (int a = 0; a <= 255; ++a)
    {
        for (int b = 0; b <= 255; ++b)
        {
            if (x86_mulhi_scaled(a, b) != neon_sqdmulh_scaled(a, b))
            {
                std::cerr << "FT scaling mismatch: a=" << a << " b=" << b << '\n';
                return false;
            }
        }
    }
    return true;
}

int32_t dotprod_sdot_model(const uint8_t* activations, const int8_t* weights, int32_t source)
{
    // SDOT adds four signed-byte products to one signed 32-bit lane. Halogen
    // feeds it activations in [0, 127], so reinterpretation from u8 to s8 is
    // value-preserving and the result is the exact signed dot product below.
    int64_t dot = 0;
    for (int i = 0; i < 4; ++i)
    {
        dot += static_cast<int32_t>(activations[i]) * static_cast<int32_t>(weights[i]);
    }
    return source + static_cast<int32_t>(dot);
}

bool check_dotprod_parity()
{
    std::mt19937 rng(0x48414C4Fu);
    std::uniform_int_distribution<int> activation_dist(0, 127);
    std::uniform_int_distribution<int> weight_dist(-128, 127);
    std::uniform_int_distribution<int32_t> source_dist(-1000000, 1000000);

    std::array<uint8_t, 16> activations {};
    std::array<int8_t, 16> weights {};
    for (int iteration = 0; iteration < 250000; ++iteration)
    {
        for (size_t i = 0; i < activations.size(); ++i)
        {
            activations[i] = static_cast<uint8_t>(activation_dist(rng));
            weights[i] = static_cast<int8_t>(weight_dist(rng));
        }
        for (int group = 0; group < 4; ++group)
        {
            const size_t offset = static_cast<size_t>(group) * 4;
            const int32_t source = source_dist(rng);
            const int32_t reference = scalar_dot4(&activations[offset], &weights[offset], source);
            const int32_t neon = neon_pairwise_dot4(&activations[offset], &weights[offset], source);
            const int32_t dotprod = dotprod_sdot_model(&activations[offset], &weights[offset], source);
            if (reference != neon || reference != dotprod)
            {
                std::cerr << "L1 dot-product mismatch at iteration " << iteration << " group " << group << '\n';
                return false;
            }
        }
    }

    // Prove the pairwise int16 partial sums cannot saturate in Halogen's [0,127] x [-128,127] domain.
    constexpr int min_pair = 2 * 127 * -128;
    constexpr int max_pair = 2 * 127 * 127;
    static_assert(min_pair >= -32768 && max_pair <= 32767);
    return true;
}

uint8_t neon_qmovun_model(int16_t value)
{
    return static_cast<uint8_t>(value < 0 ? 0 : (value > 255 ? 255 : value));
}

uint8_t x86_packus_model(int16_t value)
{
    const uint16_t positive = value < 0 ? 0 : static_cast<uint16_t>(value);
    return static_cast<uint8_t>(positive > 255 ? 255 : positive);
}

bool check_packus_contract()
{
    for (int value = -32768; value <= 32767; ++value)
    {
        const auto neon = neon_qmovun_model(static_cast<int16_t>(value));
        const auto x86 = x86_packus_model(static_cast<int16_t>(value));
        if (neon != x86)
        {
            std::cerr << "packus mismatch: value=" << value << '\n';
            return false;
        }
    }
    return true;
}

} // namespace

int main()
{
    if (!check_activation_scaling() || !check_dotprod_parity() || !check_packus_contract())
    {
        return 1;
    }
    std::cout << "PASS: exhaustive FT scale parity (65,536 cases)\n";
    std::cout << "PASS: NEON pairwise / Dotprod signed-byte dot-product parity (1,000,000 groups)\n";
    std::cout << "PASS: signed-16 to unsigned-8 saturation contract (65,536 cases)\n";
    return 0;
}
