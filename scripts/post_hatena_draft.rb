#!/usr/bin/env ruby
# frozen_string_literal: true

# はてなブログ下書き（ドラフト）投稿スクリプト（標準ライブラリのみ・外部gem不要）
#
# 【機能】
# 1. Markdownファイルの先頭 `# タイトル` を記事タイトルとして抽出
# 2. 本文内のローカル画像 (`![alt](../../screenshots/xxx.png)` 等) を検出し、
#    はてなフォトライフ AtomPub API へ自動アップロードして画像URLに置換
#    （`--github-images` 指定時はフォトライフを使わず GitHub raw URL に置換）
# 3. はてなブログ AtomPub API に下書き (`<app:draft>yes</app:draft>`) として投稿
#
# 【必要な環境変数】（`docs/blog/.hatena.env` から自動読込）
#   HATENA_ID       : はてなID (例: ongaeshi)
#   HATENA_BLOG_ID  : ブログID (例: ongaeshi.hatenablog.com)
#   HATENA_API_KEY  : AtomPub APIキー (アカウント設定 -> 基本設定 -> APIキー)
#
# 【使い方】
#   ruby scripts/post_hatena_draft.rb docs/blog/2026-10-30-devlog-1.md
#   ruby scripts/post_hatena_draft.rb docs/blog/2026-10-30-devlog-1.md --category Usakame --category Ruby
#   ruby scripts/post_hatena_draft.rb docs/blog/2026-10-30-devlog-1.md --dry-run

require 'net/http'
require 'uri'
require 'base64'
require 'digest/sha1'
require 'securerandom'
require 'time'
require 'optparse'
require 'pathname'

def load_dotenv(*paths)
  paths.each do |path|
    next unless File.exist?(path)

    File.readlines(path, chomp: true).each do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      if line =~ /\A([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\z/
        key = Regexp.last_match(1)
        val = Regexp.last_match(2).strip
        val = val[1..-2] if (val.start_with?('"') && val.end_with?('"')) || (val.start_with?("'") && val.end_with?("'"))
        ENV[key] ||= val
      end
    end
  end
end

def xml_escape(str)
  str.to_s
     .gsub('&', '&amp;')
     .gsub('<', '&lt;')
     .gsub('>', '&gt;')
     .gsub('"', '&quot;')
     .gsub("'", '&apos;')
end

def build_wsse_header(hatena_id, api_key)
  nonce_raw = SecureRandom.random_bytes(20)
  nonce_b64 = Base64.strict_encode64(nonce_raw)
  created = Time.now.utc.iso8601
  digest = Base64.strict_encode64(Digest::SHA1.digest(nonce_raw + created + api_key))
  %(UsernameToken Username="#{hatena_id}", PasswordDigest="#{digest}", Nonce="#{nonce_b64}", Created="#{created}")
end

def mime_type_for(path)
  case File.extname(path).downcase
  when '.png'          then 'image/png'
  when '.jpg', '.jpeg' then 'image/jpeg'
  when '.gif'          then 'image/gif'
  else
    raise "Unsupported image format: #{path}"
  end
end

def upload_to_fotolife(image_path, hatena_id:, api_key:, folder: 'Hatena Blog')
  uri = URI.parse('https://f.hatena.ne.jp/atom/post')
  mime = mime_type_for(image_path)
  b64_data = Base64.strict_encode64(File.binread(image_path))
  title = File.basename(image_path)

  folder_xml = folder && !folder.empty? ? "<dc:subject>#{xml_escape(folder)}</dc:subject>" : ''

  xml = <<~XML
    <?xml version="1.0" encoding="utf-8"?>
    <entry xmlns="http://purl.org/atom/ns#" xmlns:dc="http://purl.org/dc/elements/1.1/">
      <title>#{xml_escape(title)}</title>
      <content mode="base64" type="#{mime}">#{b64_data}</content>
      #{folder_xml}
    </entry>
  XML

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  req = Net::HTTP::Post.new(uri.request_uri)
  req['X-WSSE'] = build_wsse_header(hatena_id, api_key)
  req['Content-Type'] = 'application/x.atom+xml'
  req['Accept'] = 'application/x.atom+xml, application/xml, text/xml, */*'
  req.body = xml

  res = http.request(req)
  unless res.is_a?(Net::HTTPSuccess) || res.is_a?(Net::HTTPCreated)
    raise "Hatena Fotolife upload failed (#{res.code} #{res.message}):\n#{res.body}"
  end

  body = res.body.force_encoding('UTF-8')
  if body =~ %r{<hatena:imageurl>([^<]+)</hatena:imageurl>}
    Regexp.last_match(1)
  elsif body =~ %r{<hatena:syntax>([^<]+)</hatena:syntax>}
    # imageurl が取れなかった場合は syntax を返す
    "syntax:#{Regexp.last_match(1)}"
  else
    raise "Could not find <hatena:imageurl> in Fotolife response:\n#{body}"
  end
end

def post_hatena_blog_entry(title:, content:, hatena_id:, blog_id:, api_key:, categories: [], draft: true)
  uri = URI.parse("https://blog.hatena.ne.jp/#{hatena_id}/#{blog_id}/atom/entry")
  draft_str = draft ? 'yes' : 'no'
  categories_xml = categories.map { |c| %(<category term="#{xml_escape(c)}" />) }.join("\n  ")

  xml = <<~XML
    <?xml version="1.0" encoding="utf-8"?>
    <entry xmlns="http://www.w3.org/2005/Atom"
           xmlns:app="http://www.w3.org/2007/app">
      <title>#{xml_escape(title)}</title>
      <author><name>#{xml_escape(hatena_id)}</name></author>
      <content type="text/x-markdown">#{xml_escape(content)}</content>
      #{categories_xml}
      <app:control>
        <app:draft>#{draft_str}</app:draft>
      </app:control>
    </entry>
  XML

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  req = Net::HTTP::Post.new(uri.request_uri)
  req.basic_auth(hatena_id, api_key)
  req['Content-Type'] = 'application/atom+xml; charset=utf-8'
  req.body = xml

  res = http.request(req)
  unless res.is_a?(Net::HTTPSuccess) || res.is_a?(Net::HTTPCreated)
    raise "Hatena Blog entry post failed (#{res.code} #{res.message}):\n#{res.body}"
  end

  body = res.body.force_encoding('UTF-8')
  edit_ui_url = nil
  preview_url = nil
  if body =~ %r{<link[^>]*rel="alternate"[^>]*href="([^"]+)"\s*/?>}
    preview_url = Regexp.last_match(1)
  end
  if body =~ %r{<link[^>]*rel="edit"[^>]*href="([^"]+)"\s*/?>}
    atom_edit_url = Regexp.last_match(1)
    if atom_edit_url =~ %r{/atom/entry/(\d+)\z}
      entry_id = Regexp.last_match(1)
      edit_ui_url = "https://blog.hatena.ne.jp/#{hatena_id}/#{blog_id}/edit?entry=#{entry_id}"
    end
  end

  { edit_ui_url: edit_ui_url, preview_url: preview_url, raw_xml: body }
end

def extract_title_and_body(markdown_text)
  lines = markdown_text.lines
  title = nil
  body_lines = []

  lines.each do |line|
    if title.nil? && line.strip =~ /\A#\s+(.+)\z/
      title = Regexp.last_match(1).strip
    else
      body_lines << line
    end
  end

  body = body_lines.join.sub(/\A\s+/, '')
  [title || 'Untitled', body]
end

# --- CLI Options ---
options = {
  categories: [],
  draft: true,
  dry_run: false,
  github_images: false,
  github_repo: 'ongaeshi/usakame',
  github_branch: 'main',
  fotolife_folder: 'Hatena Blog'
}

parser = OptionParser.new do |opts|
  opts.banner = 'Usage: ruby scripts/post_hatena_draft.rb <markdown_file> [options]'
  opts.on('-c', '--category CATEGORY', 'Add blog category (can be specified multiple times)') do |cat|
    options[:categories] << cat
  end
  opts.on('--publish', 'Publish immediately instead of saving as draft') do
    options[:draft] = false
  end
  opts.on('--github-images', 'Replace relative image paths with GitHub raw URLs instead of uploading to Hatena Fotolife') do
    options[:github_images] = true
  end
  opts.on('--folder FOLDER', 'Hatena Fotolife folder name (default: "Hatena Blog")') do |folder|
    options[:fotolife_folder] = folder
  end
  opts.on('-n', '--dry-run', 'Parse markdown and check images without uploading or posting') do
    options[:dry_run] = true
  end
end

parser.parse!(ARGV)
md_file = ARGV.first

if md_file.nil? || !File.exist?(md_file)
  warn parser.help
  exit 1
end

repo_root = Pathname.new(__dir__).parent.expand_path
md_path = Pathname.new(md_file).expand_path
md_dir = md_path.dirname

load_dotenv(
  repo_root.join('docs/blog/.hatena.env').to_s,
  md_dir.join('.hatena.env').to_s,
  repo_root.join('.hatena.env').to_s,
  repo_root.join('.env').to_s
)

hatena_id      = ENV['HATENA_ID']
hatena_blog_id = ENV['HATENA_BLOG_ID']
hatena_api_key = ENV['HATENA_API_KEY']

unless options[:dry_run]
  missing = []
  missing << 'HATENA_ID' if hatena_id.nil? || hatena_id.empty?
  missing << 'HATENA_BLOG_ID' if hatena_blog_id.nil? || hatena_blog_id.empty?
  missing << 'HATENA_API_KEY' if hatena_api_key.nil? || hatena_api_key.empty?

  unless missing.empty?
    warn "エラー: 環境変数 #{missing.join(', ')} が設定されていません。"
    warn "`docs/blog/.hatena.env` (または環境変数) に以下を設定してください:"
    warn <<~ENV_EXAMPLE

      HATENA_ID=あなたのID
      HATENA_BLOG_ID=あなたのブログID (例: example.hatenablog.com)
      HATENA_API_KEY=あなたのAtomPub APIキー
    ENV_EXAMPLE
    exit 1
  end
end

raw_md = File.read(md_path, encoding: 'UTF-8')
title, body = extract_title_and_body(raw_md)

puts "Title: #{title}"
puts "Mode : #{options[:draft] ? 'Draft (下書き)' : 'Publish (公開)'}#{options[:dry_run] ? ' [DRY-RUN]' : ''}"

uploaded_cache = {}

# Markdown内の画像記法 ![alt](path) を検出してアップロードまたはURL置換
processed_body = body.gsub(/!\[([^\]]*)\]\(([^)]+)\)/) do |full_match|
  alt = Regexp.last_match(1)
  img_ref = Regexp.last_match(2).strip

  # すでに http:// または https:// の場合はそのまま
  if img_ref =~ %r{\Ahttps?://}
    full_match
  else
    local_img_path = md_dir.join(img_ref).expand_path
    unless local_img_path.exist?
      warn "Warning: Image file not found: #{local_img_path} (kept original link)"
      next full_match
    end

    if uploaded_cache.key?(local_img_path.to_s)
      new_url = uploaded_cache[local_img_path.to_s]
    elsif options[:github_images]
      rel_from_root = local_img_path.relative_path_from(repo_root).to_s.tr('\\', '/')
      new_url = "https://raw.githubusercontent.com/#{options[:github_repo]}/#{options[:github_branch]}/#{rel_from_root}"
      puts "  [Image -> GitHub] #{img_ref} -> #{new_url}"
      uploaded_cache[local_img_path.to_s] = new_url
    elsif options[:dry_run]
      new_url = "https://cdn-ak.f.st-hatena.com/images/fotolife/dry-run/#{local_img_path.basename}"
      puts "  [Image -> Fotolife (dry-run)] #{local_img_path.relative_path_from(repo_root)}"
      uploaded_cache[local_img_path.to_s] = new_url
    else
      print "  [Uploading to Fotolife] #{local_img_path.relative_path_from(repo_root)} ... "
      $stdout.flush
      new_url = upload_to_fotolife(
        local_img_path.to_s,
        hatena_id: hatena_id,
        api_key: hatena_api_key,
        folder: options[:fotolife_folder]
      )
      puts "OK (#{new_url})"
      uploaded_cache[local_img_path.to_s] = new_url
    end

    if new_url.start_with?('syntax:')
      "[#{new_url.sub(/\Asyntax:/, '')}]"
    else
      "![#{alt}](#{new_url})"
    end
  end
end

if options[:dry_run]
  puts "\n--- Dry Run Complete (#{uploaded_cache.size} images verified) ---"
  exit 0
end

print "\nPosting entry to Hatena Blog (#{hatena_blog_id}) ... "
$stdout.flush
result = post_hatena_blog_entry(
  title: title,
  content: processed_body,
  hatena_id: hatena_id,
  blog_id: hatena_blog_id,
  api_key: hatena_api_key,
  categories: options[:categories],
  draft: options[:draft]
)
puts "Done!"
puts "Edit URL   : #{result[:edit_ui_url]}" if result[:edit_ui_url]
puts "Preview URL: #{result[:preview_url]}" if result[:preview_url]
