import hashlib
import secrets
from typing import List, Tuple, Dict
import json


class PedersenVSS:
    def __init__(self, prime: int = 2 ** 127 - 1):
        """Initialize Pedersen VSS with a prime field"""
        self.p = prime  # Prime for finite field
        self.g = 2  # Generator (simplified, in practice use a proper generator)
        self.h = 3  # Second generator (should be independent of g)

    def mod_inverse(self, a: int, m: int) -> int:
        """Compute modular inverse using extended Euclidean algorithm"""

        def extended_gcd(a, b):
            if a == 0:
                return b, 0, 1
            gcd, x1, y1 = extended_gcd(b % a, a)
            x = y1 - (b // a) * x1
            y = x1
            return gcd, x, y

        gcd, x, _ = extended_gcd(a % m, m)
        if gcd != 1:
            raise ValueError("Modular inverse does not exist")
        return (x % m + m) % m

    def generate_polynomial(self, secret: int, threshold: int) -> List[int]:
        """Generate random polynomial with given secret as constant term"""
        coefficients = [secret]
        for _ in range(threshold - 1):
            coefficients.append(secrets.randbelow(self.p))
        return coefficients

    def evaluate_polynomial(self, coeffs: List[int], x: int) -> int:
        """Evaluate polynomial at point x using Horner's method"""
        result = 0
        for coeff in reversed(coeffs):
            result = (result * x + coeff) % self.p
        return result

    def pow_mod(self, base: int, exp: int, mod: int) -> int:
        """Fast modular exponentiation"""
        result = 1
        base = base % mod
        while exp > 0:
            if exp % 2 == 1:
                result = (result * base) % mod
            exp = exp >> 1
            base = (base * base) % mod
        return result

    def generate_shares_and_commitments(self, secret: int, threshold: int, num_shares: int) -> Tuple[
        List[Tuple[int, int]], List[int], List[int]]:
        """Generate shares and commitments for Pedersen VSS"""

        # Generate two polynomials f(x) and g(x)
        f_coeffs = self.generate_polynomial(secret, threshold)
        g_coeffs = self.generate_polynomial(0, threshold)  # g(0) = 0 for Pedersen VSS

        # Generate shares
        shares = []
        for i in range(1, num_shares + 1):
            f_i = self.evaluate_polynomial(f_coeffs, i)
            g_i = self.evaluate_polynomial(g_coeffs, i)
            shares.append((f_i, g_i))

        # Generate commitments C_j = g^{a_j} * h^{b_j} for j = 0, 1, ..., t-1
        commitments = []
        for j in range(threshold):
            # C_j = g^{f_coeffs[j]} * h^{g_coeffs[j]} mod p
            commitment = (self.pow_mod(self.g, f_coeffs[j], self.p) *
                          self.pow_mod(self.h, g_coeffs[j], self.p)) % self.p
            commitments.append(commitment)

        return shares, commitments, f_coeffs

    def verify_share(self, share_index: int, share: Tuple[int, int], commitments: List[int], threshold: int) -> bool:
        """Verify a share against commitments"""
        f_i, g_i = share

        # Compute left side: g^{f_i} * h^{g_i}
        left = (self.pow_mod(self.g, f_i, self.p) * self.pow_mod(self.h, g_i, self.p)) % self.p

        # Compute right side: product of C_j^{i^j} for j = 0 to t-1
        right = 1
        for j in range(threshold):
            power = self.pow_mod(share_index, j, self.p - 1)  # i^j mod (p-1)
            right = (right * self.pow_mod(commitments[j], power, self.p)) % self.p

        return left == right

    def lagrange_interpolation(self, shares: List[Tuple[int, Tuple[int, int]]], threshold: int) -> int:
        """Reconstruct secret using Lagrange interpolation"""
        if len(shares) < threshold:
            raise ValueError("Not enough shares for reconstruction")

        # Use first 'threshold' shares
        shares = shares[:threshold]

        secret = 0
        for i, (x_i, (f_i, _)) in enumerate(shares):
            # Compute Lagrange coefficient
            numerator = 1
            denominator = 1

            for j, (x_j, _) in enumerate(shares):
                if i != j:
                    numerator = (numerator * (-x_j)) % self.p
                    denominator = (denominator * (x_i - x_j)) % self.p

            # Compute lagrange coefficient
            lagrange_coeff = (numerator * self.mod_inverse(denominator, self.p)) % self.p
            secret = (secret + f_i * lagrange_coeff) % self.p

        return secret

    def hash_secret(self, secret: int) -> str:
        """Generate hash of secret for on-chain storage"""
        secret_bytes = secret.to_bytes(32, byteorder='big')
        return hashlib.sha256(secret_bytes).hexdigest()


class CryptoWill:
    def __init__(self, prime: int = 2 ** 127 - 1):
        self.vss = PedersenVSS(prime)

    def create_will(self, heirs: List[str], heir_percentages: List[int],
                    num_trustees: int, threshold: int) -> Dict:
        """Create a crypto will with Pedersen VSS"""

        # Validate inputs
        if len(heirs) != len(heir_percentages):
            raise ValueError("Number of heirs must match number of percentages")

        if sum(heir_percentages) != 100:
            raise ValueError("Percentages must sum to 100")

        if threshold > num_trustees:
            raise ValueError("Threshold cannot exceed number of trustees")

        # Generate secret key
        secret = secrets.randbelow(self.vss.p)
        secret_hash = self.vss.hash_secret(secret)

        # Generate shares and commitments
        shares, commitments, f_coeffs = self.vss.generate_shares_and_commitments(
            secret, threshold, num_trustees
        )

        # Prepare trustee data
        trustee_shares = []
        for i, share in enumerate(shares):
            trustee_shares.append({
                'trustee_index': i + 1,
                'share': share,
                'verified': False,
                'revealed': False
            })

        will_data = {
            'secret': secret,
            'secret_hash': secret_hash,
            'heirs': heirs,
            'heir_percentages': heir_percentages,
            'num_trustees': num_trustees,
            'threshold': threshold,
            'commitments': commitments,
            'trustee_shares': trustee_shares,
            'f_coefficients': f_coeffs,
            'prime': self.vss.p,
            'generator_g': self.vss.g,
            'generator_h': self.vss.h
        }

        return will_data

    def verify_trustee_share(self, will_data: Dict, trustee_index: int) -> bool:
        """Verify a trustee's share"""
        trustee_data = will_data['trustee_shares'][trustee_index - 1]
        share = trustee_data['share']

        is_valid = self.vss.verify_share(
            trustee_index,
            share,
            will_data['commitments'],
            will_data['threshold']
        )

        if is_valid:
            trustee_data['verified'] = True

        return is_valid

    def reconstruct_secret(self, will_data: Dict, revealed_shares: List[Tuple[int, Tuple[int, int]]]) -> Tuple[
        bool, int]:
        """Reconstruct secret from revealed shares"""
        if len(revealed_shares) < will_data['threshold']:
            return False, 0

        reconstructed_secret = self.vss.lagrange_interpolation(
            revealed_shares,
            will_data['threshold']
        )

        # Verify reconstructed secret matches original hash
        reconstructed_hash = self.vss.hash_secret(reconstructed_secret)
        original_hash = will_data['secret_hash']

        return reconstructed_hash == original_hash, reconstructed_secret


# Example usage
def main():
    # Create crypto will system
    crypto_will = CryptoWill()

    # Define heirs and their inheritance percentages
    heirs = [
        "0x1234567890123456789012345678901234567890",
        "0x2345678901234567890123456789012345678901",
        "0x3456789012345678901234567890123456789012"
    ]
    heir_percentages = [50, 30, 20]  # 50%, 30%, 20%

    # Create will with 5 trustees, threshold of 3
    num_trustees = 5
    threshold = 3

    print("Creating crypto will...")
    will_data = crypto_will.create_will(heirs, heir_percentages, num_trustees, threshold)

    print(f"Secret: {will_data['secret']}")
    print(f"Secret Hash: {will_data['secret_hash']}")
    print(f"Commitments: {will_data['commitments']}")
    print(f"Number of trustees: {num_trustees}")
    print(f"Threshold: {threshold}")

    # Verify all trustee shares
    print("\nVerifying trustee shares...")
    for i in range(1, num_trustees + 1):
        is_valid = crypto_will.verify_trustee_share(will_data, i)
        print(f"Trustee {i} share valid: {is_valid}")

    # Simulate revelation of threshold number of shares
    print("\nSimulating secret reconstruction...")
    revealed_shares = []
    for i in range(threshold):
        trustee_index = i + 1
        share = will_data['trustee_shares'][i]['share']
        revealed_shares.append((trustee_index, share))

    success, reconstructed_secret = crypto_will.reconstruct_secret(will_data, revealed_shares)
    print(f"Reconstruction successful: {success}")
    print(f"Reconstructed secret matches: {reconstructed_secret == will_data['secret']}")

    # Export data for Solidity contract
    contract_data = {
        'secret_hash': will_data['secret_hash'],
        'commitments': will_data['commitments'],
        'heirs': will_data['heirs'],
        'heir_percentages': will_data['heir_percentages'],
        'num_trustees': num_trustees,
        'threshold': threshold,
        'prime': will_data['prime'],
        'generator_g': will_data['generator_g'],
        'generator_h': will_data['generator_h']
    }

    print(f"\nContract deployment data:")
    print(json.dumps(contract_data, indent=2))


if __name__ == "__main__":
    main()