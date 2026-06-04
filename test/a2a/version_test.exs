defmodule A2A.VersionTest do
  use ExUnit.Case, async: true

  alias A2A.Version

  doctest A2A.Version

  describe "default/0" do
    test "returns the library's current version" do
      assert Version.default() == "1.0"
    end
  end

  describe "supported_default/0" do
    test "accepts both 0.3 and 1.0" do
      assert Version.supported_default() == ["0.3", "1.0"]
    end
  end

  describe "normalize/1" do
    test "treats nil and empty as 0.3" do
      assert Version.normalize(nil) == "0.3"
      assert Version.normalize("") == "0.3"
      assert Version.normalize("   ") == "0.3"
    end

    test "passes Major.Minor through unchanged" do
      assert Version.normalize("1.0") == "1.0"
      assert Version.normalize("0.3") == "0.3"
    end

    test "strips patch components" do
      assert Version.normalize("1.0.3") == "1.0"
      assert Version.normalize("0.3.0") == "0.3"
    end

    test "trims surrounding whitespace" do
      assert Version.normalize("  1.0  ") == "1.0"
    end

    test "passes garbage through trimmed for the error path" do
      assert Version.normalize("abc") == "abc"
      assert Version.normalize("1") == "1"
    end
  end

  describe "parse_header/1" do
    test "missing or empty returns 0.3" do
      assert Version.parse_header(nil) == "0.3"
      assert Version.parse_header([]) == "0.3"
      assert Version.parse_header([""]) == "0.3"
    end

    test "normalizes the first value from a Plug header list" do
      assert Version.parse_header(["1.0"]) == "1.0"
      assert Version.parse_header(["1.0.3"]) == "1.0"
    end

    test "accepts a bare string" do
      assert Version.parse_header("0.3") == "0.3"
    end
  end

  describe "validate/2" do
    test "returns :ok for supported versions" do
      assert Version.validate("1.0", ["0.3", "1.0"]) == :ok
      assert Version.validate("0.3", ["0.3", "1.0"]) == :ok
    end

    test "returns {:error, version} for unsupported" do
      assert Version.validate("9.9", ["0.3", "1.0"]) == {:error, "9.9"}
      assert Version.validate("abc", ["0.3", "1.0"]) == {:error, "abc"}
    end

    test "honors a narrowed supported list" do
      assert Version.validate("0.3", ["1.0"]) == {:error, "0.3"}
    end
  end
end
