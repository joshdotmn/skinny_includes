# Release Checklist

## Before Release

1. **Update version** in `lib/skinny_includes/version.rb`
2. **Update CHANGELOG.md** with version and date
3. **Run tests**: `ruby spec/skinny_includes_spec.rb`
4. **Commit all changes**
5. **Push to GitHub**

## Release

Run the release script:

```bash
bin/release
```

This will:
- ✅ Check git is clean
- ✅ Check version tag doesn't exist
- ✅ Run tests
- ✅ Build gem
- ✅ Show files included
- ✅ Ask for confirmation
- ✅ Push to rubygems.org
- ✅ Create and push git tag

## Manual Release (if needed)

```bash
# Build
gem build skinny_includes.gemspec

# Push
gem push skinny_includes-0.1.0.gem

# Tag
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

## After Release

1. Verify on rubygems.org: https://rubygems.org/gems/skinny_includes
2. Test installation: `gem install skinny_includes`
3. Update any dependent projects

## Troubleshooting

### "Repushing of gem versions is not allowed"
You've already pushed this version. Bump the version number.

### "You are not authorized to push"
Run: `gem signin` or check your rubygems.org credentials

### "Git tag already exists"
Either delete the tag or bump the version:
```bash
git tag -d v0.1.0
git push origin :refs/tags/v0.1.0
```
