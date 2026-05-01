import sys

def string_to_hex(value):
    return ''.join(format(ord(char), '02x') for char in value)

def main():
    if len(sys.argv) != 2:
        print("Usage: python convert_option_143.py <URL_or_URI>")
        sys.exit(1)

    # Get the input URL or URI from command line arguments
    value = sys.argv[1]

    # Convert the string to hexadecimal
    hex_value = string_to_hex(value)

    # Length prefix is the number of bytes in the URL (1 byte per ASCII char)
    byte_length = len(value.encode('ascii'))

    # Convert byte length to 2-byte hex prefix
    hex_half_length = format(byte_length, '04x')

    # Combine to make option 143 hex string
    combined_hex = f"{hex_half_length}.{'.'.join([hex_value[i:i+4] for i in range(0, len(hex_value), 4)])}"

    # Output the results
    print(f"Original value: {value}")
    print(f"Hexadecimal value: {hex_value}")
    print(f"Byte length: {byte_length} (decimal), {hex_half_length} (hex)")
    print(f"Option 143 hex string: {combined_hex}")

    # Additional line for copy-paste
    print(f"option 143 hex {combined_hex}")

if __name__ == "__main__":
    main()
