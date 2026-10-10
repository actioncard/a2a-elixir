defmodule A2A.FileContentTest do
  use ExUnit.Case, async: true

  alias A2A.FileContent

  describe "from_bytes/2" do
    test "creates file content with inline bytes" do
      fc = FileContent.from_bytes("hello")
      assert fc.bytes == "hello"
      assert fc.uri == nil
      assert fc.name == nil
      assert fc.mime_type == nil
    end

    test "accepts name option" do
      fc = FileContent.from_bytes("data", name: "report.txt")
      assert fc.name == "report.txt"
      assert fc.bytes == "data"
    end

    test "accepts mime_type option" do
      fc = FileContent.from_bytes("data", mime_type: "text/plain")
      assert fc.mime_type == "text/plain"
    end

    test "accepts both name and mime_type" do
      fc = FileContent.from_bytes(<<0, 1, 2>>, name: "image.png", mime_type: "image/png")
      assert fc.name == "image.png"
      assert fc.mime_type == "image/png"
      assert fc.bytes == <<0, 1, 2>>
      assert fc.uri == nil
    end
  end

  describe "from_uri/2" do
    test "creates file content with a URI reference" do
      fc = FileContent.from_uri("https://example.com/file.pdf")
      assert fc.uri == "https://example.com/file.pdf"
      assert fc.bytes == nil
      assert fc.name == nil
      assert fc.mime_type == nil
    end

    test "accepts name option" do
      fc = FileContent.from_uri("s3://bucket/key", name: "doc.pdf")
      assert fc.name == "doc.pdf"
      assert fc.uri == "s3://bucket/key"
    end

    test "accepts mime_type option" do
      fc = FileContent.from_uri("https://example.com/f", mime_type: "application/pdf")
      assert fc.mime_type == "application/pdf"
    end

    test "accepts both name and mime_type" do
      fc = FileContent.from_uri("https://cdn.example.com/img.jpg",
        name: "photo.jpg",
        mime_type: "image/jpeg"
      )

      assert fc.name == "photo.jpg"
      assert fc.mime_type == "image/jpeg"
      assert fc.uri == "https://cdn.example.com/img.jpg"
      assert fc.bytes == nil
    end
  end

  describe "struct" do
    test "can be created directly" do
      fc = %FileContent{bytes: "raw", name: "f.bin"}
      assert fc.bytes == "raw"
      assert fc.name == "f.bin"
      assert fc.uri == nil
      assert fc.mime_type == nil
    end

    test "all fields default to nil" do
      fc = %FileContent{}
      assert fc.bytes == nil
      assert fc.uri == nil
      assert fc.name == nil
      assert fc.mime_type == nil
    end
  end
end
